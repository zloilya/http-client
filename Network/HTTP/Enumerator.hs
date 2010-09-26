{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
-- | This module contains everything you need to initiate HTTP connections.
-- Make sure to wrap your code with 'withHttpEnumerator'. If you want a simple
-- interface based on URLs, you can use 'simpleHttp'. If you want raw power,
-- 'http' is the underlying workhorse of this package. Some examples:
--
-- > -- Just download an HTML document and print it.
-- > import Network.HTTP.Enumerator
-- > import qualified Data.ByteString.Lazy as L
-- >
-- > main = simpleHttp "http://www.haskell.org/" >>= L.putStr
--
-- This example uses interleaved IO to write the response body to a file in
-- constant memory space. By using 'httpRedirect', it will automatically
-- follow 3xx redirects.
--
-- > import Network.HTTP.Enumerator
-- > import Data.Enumerator.IO
-- > import System.IO
-- >
-- > main = withFile "google.html" WriteMode $ \handle -> do
-- >     request <- parseUrl "http://google.com/"
-- >     httpRedirect (\_ _ -> iterHandle handle) request
--
-- The following headers are automatically set by this module, and should not
-- be added to 'requestHeaders':
--
-- * Content-Length
--
-- * Host
--
-- * Accept-Encoding (not currently set, but client usage of this variable /will/ cause breakage).
module Network.HTTP.Enumerator
    ( -- * Perform a request
      simpleHttp
    , httpLbs
    , httpLbsRedirect
    , http
    , httpRedirect
      -- * Datatypes
    , Request (..)
    , Response (..)
    , Headers
      -- * Utility functions
    , parseUrl
    , withHttpEnumerator
    , lbsIter
      -- * Request bodies
    , urlEncodedBody
      -- * Exceptions
    , InvalidUrlException (..)
    , HttpException (..)
    ) where

#if OPENSSL
import OpenSSL
import qualified OpenSSL.Session as SSL
#else
import System.IO (hClose, hSetBuffering, BufferMode (NoBuffering))
import qualified Network.TLS.Client as TLS
import qualified Network.TLS.Struct as TLS
import qualified Network.TLS.Cipher as TLS
import qualified Network.TLS.SRandom as TLS
import qualified Control.Monad.State as MTL
import Data.IORef
import Network (connectTo, PortID (PortNumber))
import qualified Codec.Crypto.AES.Random as AESRand
import Control.Applicative ((<$>))
#endif

import Network.Socket
import qualified Network.Socket.ByteString as B
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as S8
import Data.Enumerator hiding (head, map, break)
import qualified Data.Enumerator as E
import Network.HTTP.Enumerator.HttpParser
import Control.Exception (throwIO, Exception)
import Control.Arrow (first)
import Data.Char (toLower)
import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Class (lift)
import Control.Failure
import Data.Typeable (Typeable)
import Data.Data (Data)
import Data.Word (Word8)
import Data.Bits
import Data.Maybe (fromMaybe)
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Codec.Binary.UTF8.String (encodeString)
import qualified Text.Blaze.Builder.Core as Blaze
import Data.Monoid (Monoid (..))

-- | The OpenSSL library requires some initialization of variables to be used,
-- and therefore you must call 'withOpenSSL' before using any of its functions.
-- As this library uses OpenSSL, you must use 'withOpenSSL' as well. (As a side
-- note, you'll also want to use the withSocketsDo function for network
-- activity.)
--
-- To future-proof this package against switching to different SSL libraries,
-- we re-export 'withOpenSSL' under this name. You can call this function as
-- early as you like; in fact, simply wrapping the do block of your main
-- function is probably best.
withHttpEnumerator :: IO a -> IO a
#if OPENSSL
withHttpEnumerator = withOpenSSL
#else
withHttpEnumerator = id
#endif

getSocket :: String -> Int -> IO Socket
getSocket host' port' = do
    addrs <- getAddrInfo Nothing (Just host') (Just $ show port')
    let addr = head addrs
    sock <- socket (addrFamily addr) Stream defaultProtocol
    connect sock (addrAddress addr)
    return sock

withSocketConn :: MonadIO m => String -> Int -> (HttpConn -> m a) -> m a
withSocketConn host' port' f = do
    sock <- liftIO $ getSocket host' port'
    a <- f HttpConn
        { hcRead = B.recv sock
        , hcWrite = B.sendAll sock
        }
    liftIO $ sClose sock
    return a

withSslConn :: MonadIO m => String -> Int -> (HttpConn -> m a) -> m a
withSslConn host' port' f = do

#if OPENSSL
    ctx <- liftIO $ SSL.context
    sock <- liftIO $ getSocket host' port'
    ssl <- liftIO $ SSL.connection ctx sock
    liftIO $ SSL.connect ssl
    a <- f HttpConn
        { hcRead = SSL.read ssl
        , hcWrite = SSL.write ssl
        }
    liftIO $ SSL.shutdown ssl SSL.Unidirectional
    return a
#else
    ranByte <- liftIO $ S.head <$> AESRand.randBytes 1
    _ <- liftIO $ AESRand.randBytes (fromIntegral ranByte)
    Just clientRandom <- liftIO $ TLS.clientRandom . S.unpack <$> AESRand.randBytes 32
    premasterRandom <- liftIO $ (TLS.ClientKeyData . S.unpack) <$> AESRand.randBytes 46
    seqInit <- liftIO $ conv . S.unpack <$> AESRand.randBytes 4
    handle <- liftIO $ connectTo host' (PortNumber $ fromIntegral port')
    liftIO $ hSetBuffering handle NoBuffering
    let params = TLS.TLSClientParams
            TLS.TLS10
            [TLS.TLS10]
            Nothing
            [ TLS.cipher_AES128_SHA1
            , TLS.cipher_AES256_SHA1
            , TLS.cipher_RC4_128_MD5
            , TLS.cipher_RC4_128_SHA1
            ]
            Nothing
            (TLS.TLSClientCallbacks Nothing)

    ((), state) <- liftIO $ TLS.runTLSClient (do
        TLS.connect handle clientRandom premasterRandom
        ) params $ TLS.makeSRandomGen seqInit
    istate <- liftIO $ newIORef state
    a <- f HttpConn
        { hcRead = \_len -> do
            state1 <- readIORef istate
            (a, state2) <-
                flip MTL.runStateT state1
              $ TLS.runTLSC
              $ TLS.recvData handle
            writeIORef istate state2
            return $ S.concat $ L.toChunks a
        , hcWrite = \bs -> do
            S.putStr bs
            state1 <- readIORef istate
            state2 <-
                flip MTL.execStateT state1
              $ TLS.runTLSC
              $ TLS.sendData handle
              $ L.fromChunks [bs]
            writeIORef istate state2
        }
    state' <- liftIO $ readIORef istate
    _state'' <- liftIO $ flip MTL.execStateT state'
              $ TLS.runTLSC $ TLS.close handle
    liftIO $ hClose handle
    return a

conv :: [Word8] -> Int
conv l = (a `shiftL` 24) .|. (b `shiftL` 16) .|. (c `shiftL` 8) .|. d
    where
        [a,b,c,d] = map fromIntegral l
#endif

data HttpConn = HttpConn
    { hcRead :: Int -> IO S.ByteString
    , hcWrite :: S.ByteString -> IO ()
    }

connToEnum :: MonadIO m => HttpConn -> Enumerator S.ByteString m a
connToEnum (HttpConn r _) =
    Iteratee . loop
  where
    loop (Continue k) = do
#if DEBUG
        bs <- r 5
        liftIO $ putStrLn $ "connToEnum: read 2 bytes: " ++ show bs
#else
        bs <- liftIO $ r defaultChunkSize
#endif
        if S.null bs
            then return $ Continue k
            else do
                runIteratee (k $ Chunks [bs]) >>= loop
    loop step = return step

-- | All information on how to connect to a host and what should be sent in the
-- HTTP request.
--
-- If you simply wish to download from a URL, see 'parseUrl'.
data Request = Request
    { method :: S.ByteString -- ^ HTTP request method, eg GET, POST.
    , secure :: Bool -- ^ Whether to use HTTPS (ie, SSL).
    , host :: S.ByteString
    , port :: Int
    , path :: S.ByteString -- ^ Everything from the host to the query string.
    , queryString :: Headers -- ^ Automatically escaped for your convenience.
    , requestHeaders :: Headers
    , requestBody :: L.ByteString
    }
    deriving (Show, Read, Eq, Typeable, Data)

-- | A simple representation of the HTTP response created by 'lbsIter'.
data Response = Response
    { statusCode :: Int
    , responseHeaders :: Headers
    , responseBody :: L.ByteString
    }
    deriving (Show, Read, Eq, Typeable, Data)

type Headers = [(S.ByteString, S.ByteString)]

-- | The most low-level function for initiating an HTTP request.
--
-- The second argument to this function gives a full specification on the
-- request: the host to connect to, whether to use SSL, headers, etc. Please
-- see 'Request' for full details.
--
-- The first argument specifies how the response should be handled. It's a
-- function that takes two arguments: the first is the HTTP status code of the
-- response, and the second is a list of all response headers. This module
-- exports 'lbsIter', which generates a 'Response' value.
--
-- Note that this allows you to have fully interleaved IO actions during your
-- HTTP download, making it possible to download very large responses in
-- constant memory.
http :: MonadIO m
     => (Int -> Headers -> Iteratee S.ByteString m a)
     -> Request
     -> m a
http bodyIter Request {..} = do
    let h' = S8.unpack host
    let withConn = if secure then withSslConn else withSocketConn
    res <- withConn h' port go
    case res of
        Left e -> liftIO $ throwIO e
        Right x -> return x
  where
    hh
        | port == 80 && not secure = host
        | port == 443 && secure = host
        | otherwise = host `S.append` S8.pack (':' : show port)
    go hc = do
        liftIO $ hcWrite hc $ S.concat
            $ method
            : " "
            : (case S8.uncons path of
                Just ('/', _) -> (:) path
                _ -> ((:) "/") . ((:) path))
            (renderQS queryString [" HTTP/1.1\r\n"])
        let headers' = ("Host", hh)
                     : ("Content-Length", S8.pack $ show
                                                  $ L.length requestBody)
                     : requestHeaders
        liftIO $ forM_ headers' $ \(k, v) -> hcWrite hc $ S.concat
            [ k
            , ": "
            , v
            , "\r\n"
            ]
        liftIO $ hcWrite hc "\r\n"
        liftIO $ mapM_ (hcWrite hc) $ L.toChunks requestBody
        run $ connToEnum hc $$ do
            ((_, sc, _), hs) <- iterHeaders
            let hs' = map (first $ S8.map toLower) hs
            let mcl = lookup "content-length" hs'
            let body' =
                    if ("transfer-encoding", "chunked") `elem` hs'
                        then iterChunks'
                        else case mcl >>= readMay . S8.unpack of
                            Just len -> takeLBS len
                            Nothing -> E.map id
            bodyStep <- lift $ runIteratee $ bodyIter sc hs
            bodyStep' <- body' bodyStep
            eres <- lift $ run $ Iteratee $ return bodyStep'
            case eres of
                Left err -> liftIO $ throwIO err
                Right res -> return res

iterChunks' :: MonadIO m => Enumeratee S.ByteString S.ByteString m a
iterChunks' k@(Continue _) = do
#if DEBUG
    liftIO $ putStrLn "iterChunkHeader start"
#endif
    len <- iterChunkHeader
#if DEBUG
    liftIO $ putStrLn $ "iterChunkHeader stop: " ++ show len
#endif
    if len == 0
        then return k
        else do
            k' <- takeLBS len k
#if DEBUG
            liftIO $ putStrLn "iterNewline start"
#endif
            iterNewline
#if DEBUG
            liftIO $ putStrLn "iterNewline stop"
#endif
            iterChunks' k'
iterChunks' step = return step

takeLBS :: MonadIO m => Int -> Enumeratee S.ByteString S.ByteString m a
takeLBS 0 step = return step
takeLBS len (Continue k) = do
    mbs <- E.head
    case mbs of
        Nothing -> return $ Continue k
        Just bs -> do
            let (len', chunk, rest) =
                    if S.length bs > len
                        then (0, S.take len bs,
                                if S.length bs == len
                                    then Chunks []
                                    else Chunks [S.drop len bs])
                        else (len - S.length bs, bs, Chunks [])
            step' <- lift $ runIteratee $ k $ Chunks [chunk]
            if len' == 0
                then yield step' rest
                else takeLBS len' step'
takeLBS _ step = return step

renderQS :: [(S.ByteString, S.ByteString)]
         -> [S.ByteString]
         -> [S.ByteString]
renderQS [] x = x
renderQS (p:ps) x =
    go "?" p ++ concatMap (go "&") ps ++ x
  where
    go sep (k, v) = [sep, escape k, "=", escape v]
    escape = S8.concatMap (S8.pack . encodeUrlChar)

encodeUrlCharPI :: Char -> String
encodeUrlCharPI '/' = "/"
encodeUrlCharPI c = encodeUrlChar c

encodeUrlChar :: Char -> String
encodeUrlChar c
    -- List of unreserved characters per RFC 3986
    -- Gleaned from http://en.wikipedia.org/wiki/Percent-encoding
    | 'A' <= c && c <= 'Z' = [c]
    | 'a' <= c && c <= 'z' = [c]
    | '0' <= c && c <= '9' = [c]
encodeUrlChar c@'-' = [c]
encodeUrlChar c@'_' = [c]
encodeUrlChar c@'.' = [c]
encodeUrlChar c@'~' = [c]
encodeUrlChar ' ' = "+"
encodeUrlChar y =
    let (a, c) = fromEnum y `divMod` 16
        b = a `mod` 16
        showHex' x
            | x < 10 = toEnum $ x + (fromEnum '0')
            | x < 16 = toEnum $ x - 10 + (fromEnum 'A')
            | otherwise = error $ "Invalid argument to showHex: " ++ show x
     in ['%', showHex' b, showHex' c]

-- | Thrown by 'parseUrl' when a URL could not be parsed correctly.
--
-- 'httpRedirect' also uses the 'parseUrl' function to read the location header
-- from a server, so it can also throw this exception.
data InvalidUrlException = InvalidUrlException String String
    deriving (Show, Typeable)
instance Exception InvalidUrlException

-- | Convert a URL into a 'Request'.
--
-- This defaults some of the values in 'Request', such as setting 'method' to
-- GET and 'requestHeaders' to @[]@.
--
-- Since this function uses 'Failure', the return monad can be anything that is
-- an instance of 'Failure', such as 'IO' or 'Maybe'.
parseUrl :: Failure InvalidUrlException m => String -> m Request
parseUrl s@('h':'t':'t':'p':':':'/':'/':rest) = parseUrl1 s False rest
parseUrl s@('h':'t':'t':'p':'s':':':'/':'/':rest) = parseUrl1 s True rest
parseUrl x = failure $ InvalidUrlException x "Invalid scheme"

parseUrl1 :: Failure InvalidUrlException m
          => String -> Bool -> String -> m Request
parseUrl1 full sec s =
    parseUrl2 full sec s'
  where
    s' = encodeString s

parseUrl2 :: Failure InvalidUrlException m
          => String -> Bool -> String -> m Request
parseUrl2 full sec s = do
    port' <- mport
    return Request
        { host = S8.pack hostname
        , port = port'
        , secure = sec
        , requestHeaders = []
        , path = S8.pack $ if null path'
                            then "/"
                            else concatMap encodeUrlCharPI path'
        , queryString = parseQueryString $ S8.pack qstring
        , requestBody = L.empty
        , method = "GET"
        }
  where
    (beforeSlash, afterSlash) = break (== '/') s
    (hostname, portStr) = break (== ':') beforeSlash
    (path', qstring') = break (== '?') afterSlash
    qstring'' = case qstring' of
                '?':x -> x
                _ -> qstring'
    qstring = takeWhile (/= '#') qstring''
    mport =
        case (portStr, sec) of
            ("", False) -> return 80
            ("", True) -> return 443
            (':':rest, _) ->
                case readMay rest of
                    Just i -> return i
                    Nothing -> failure $ InvalidUrlException full "Invalid port"
            x -> error $ "parseUrl1: this should never happen: " ++ show x

parseQueryString :: S.ByteString -> [(S.ByteString, S.ByteString)]
parseQueryString = parseQueryString' . dropQuestion
  where
    dropQuestion q | S.null q || S.head q /= 63 = q
    dropQuestion q | otherwise = S.tail q
    parseQueryString' q | S.null q = []
    parseQueryString' q =
        let (x, xs) = breakDiscard 38 q -- ampersand
         in parsePair x : parseQueryString' xs
      where
        parsePair x =
            let (k, v) = breakDiscard 61 x -- equal sign
             in (qsDecode k, qsDecode v)


qsDecode :: S.ByteString -> S.ByteString
qsDecode z = fst $ S.unfoldrN (S.length z) go z
  where
    go bs =
        case uncons bs of
            Nothing -> Nothing
            Just (43, ws) -> Just (32, ws) -- plus to space
            Just (37, ws) -> Just $ fromMaybe (37, ws) $ do -- percent
                (x, xs) <- uncons ws
                x' <- hexVal x
                (y, ys) <- uncons xs
                y' <- hexVal y
                Just $ (combine x' y', ys)
            Just (w, ws) -> Just (w, ws)
    hexVal w
        | 48 <= w && w <= 57  = Just $ w - 48 -- 0 - 9
        | 65 <= w && w <= 70  = Just $ w - 55 -- A - F
        | 97 <= w && w <= 102 = Just $ w - 87 -- a - f
        | otherwise = Nothing
    combine :: Word8 -> Word8 -> Word8
    combine a b = shiftL a 4 .|. b

uncons :: S.ByteString -> Maybe (Word8, S.ByteString)
uncons s
    | S.null s = Nothing
    | otherwise = Just (S.head s, S.tail s)

breakDiscard :: Word8 -> S.ByteString -> (S.ByteString, S.ByteString)
breakDiscard w s =
    let (x, y) = S.break (== w) s
     in (x, S.drop 1 y)

-- | Convert the HTTP response into a 'Response' value.
--
-- Even though a 'Response' contains a lazy bytestring, this function does
-- /not/ utilize lazy I/O, and therefore the entire response body will live in
-- memory. If you want constant memory usage, you'll need to write your own
-- iteratee and use 'http' or 'httpRedirect' directly.
lbsIter :: Monad m => Int -> Headers -> Iteratee S.ByteString m Response
lbsIter sc hs = do
#if DEBUG
    b <- fmap L.fromChunks consume'
#else
    b <- fmap L.fromChunks consume
#endif
    return $ Response sc hs b

-- | Download the specified 'Request', returning the results as a 'Response'.
--
-- This is a simplified version of 'http' for the common case where you simply
-- want the response data as a simple datatype. If you want more power, such as
-- interleaved actions on the response body during download, you'll need to use
-- 'http' directly. This function is defined as:
--
-- @httpLbs = http lbsIter@
--
-- Please see 'lbsIter' for more information on how the 'Response' value is
-- created.
httpLbs :: MonadIO m => Request -> m Response
httpLbs = http lbsIter

#if DEBUG
consume' =
    liftI step
  where
    step chunk = case chunk of
        Chunks [] -> Continue $ returnI . step
        Chunks xs -> Continue $ \stream -> do
            liftIO $ putStrLn $ "consume': received Chunks: " ++ show xs
            returnI $ step stream
        EOF -> Yield [] EOF
#endif

-- | Download the specified URL, following any redirects, and return the
-- response body.
--
-- This function will 'failure' an 'HttpException' for any response with a
-- non-2xx status code. It uses 'parseUrl' to parse the input. This function
-- essentially wraps 'httpLbsRedirect'.
simpleHttp :: ( Failure InvalidUrlException m
              , Failure HttpException m
              , MonadIO m)
           => String -> m L.ByteString
simpleHttp url = do
    url' <- parseUrl url
    Response sc _ b <- httpLbsRedirect url'
    if 200 <= sc && sc < 300
        then return b
        else failure $ HttpException sc b

-- | Throw by 'simpleHttp' when a response does not have a 2xx status code.
data HttpException = HttpException Int L.ByteString
    deriving (Show, Typeable)
instance Exception HttpException

-- | Same as 'http', but follows all 3xx redirect status codes that contain a
-- location header.
httpRedirect
    :: (MonadIO m, Failure InvalidUrlException m)
    => (Int -> Headers -> Iteratee S.ByteString m a)
    -> Request
    -> m a
httpRedirect iter req =
    http iter' req
  where
    iter' code hs
        | 300 <= code && code < 400 =
            case lookup "location" $ map (first $ S8.map toLower) hs of
                Just l'' -> lift $ do
                    -- Prepend scheme, host and port if missing
                    let l' =
                            case S8.uncons l'' of
                                Just ('/', _) -> concat
                                    [ "http"
                                    , if secure req then "s" else ""
                                    , "://"
                                    , S8.unpack $ host req
                                    , ":"
                                    , show $ port req
                                    , S8.unpack l''
                                    ]
                                _ -> S8.unpack l''
                    l <- parseUrl l'
                    let req' = req
                            { host = host l
                            , port = port l
                            , secure = secure l
                            , path = path l
                            , queryString = queryString l
                            }
                    http iter req'
                Nothing -> iter code hs
        | otherwise = iter code hs

-- | Download the specified 'Request', returning the results as a 'Response'
-- and automatically handling redirects.
--
-- This is a simplified version of 'httpRedirect' for the common case where you
-- simply want the response data as a simple datatype. If you want more power,
-- such as interleaved actions on the response body during download, you'll
-- need to use 'httpRedirect' directly. This function is defined as:
--
-- @httpLbsRedirect = httpRedirect lbsIter@
--
-- Please see 'lbsIter' for more information on how the 'Response' value is
-- created.
httpLbsRedirect :: ( Failure InvalidUrlException m
                   , MonadIO m)
                => Request -> m Response
httpLbsRedirect = httpRedirect lbsIter

readMay :: Read a => String -> Maybe a
readMay s = case reads s of
                [] -> Nothing
                (x, _):_ -> Just x

-- | Add url-encoded paramters to the 'Request'.
--
-- This sets a new 'requestBody', adds a content-type request header and
-- changes the 'method' to POST.
urlEncodedBody :: Headers -> Request -> Request
urlEncodedBody headers req = req
    { requestBody = body
    , method = "POST"
    , requestHeaders =
        (ct, "application/x-www-form-urlencoded")
      : filter (\(x, _) -> x /= ct) (requestHeaders req)
    }
  where
    ct = "Content-Type"
    body = Blaze.toLazyByteString $ body' headers
    body' [] = mempty
    body' [x] = pair x
    body' (x:xs) = pair x `mappend` Blaze.singleton 38 `mappend` body' xs
    pair (x, y)
        | S.null y = single x
        | otherwise =
            single x `mappend` Blaze.singleton 61 `mappend` single y
    single = Blaze.writeList go . S.unpack
    go 32 = Blaze.writeByte 43 -- space to plus
    go c | unreserved c = Blaze.writeByte c
    go c =
        let x = shiftR c 4
            y = c .&. 15
         in Blaze.writeByte 37 `mappend` hexChar x `mappend` hexChar y
    unreserved  45 = True -- hyphen
    unreserved  46 = True -- period
    unreserved  95 = True -- underscore
    unreserved 126 = True -- tilde
    unreserved c
        | 48 <= c && c <= 57  = True -- 0 - 9
        | 65 <= c && c <= 90  = True -- A - Z
        | 97 <= c && c <= 122 = True -- A - Z
    unreserved _ = False
    hexChar c
        | c < 10 = Blaze.writeByte $ c + 48
        | c < 16 = Blaze.writeByte $ c + 55
        | otherwise = error $ "hexChar: " ++ show c
