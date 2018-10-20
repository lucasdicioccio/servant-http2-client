{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE MultiParamTypeClasses   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeOperators  #-}

module Main where

import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Lazy (fromStrict, toStrict)
import           Data.Default.Class (def)
import           Data.Text (Text)
import           Data.Text.Encoding as Encoding
import           Data.Proxy
import           Network.HTTP2.Client
import           Network.HTTP2.Client.Servant
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import           Servant.API
import           Servant.Client.Core

data RawText
instance Accept RawText where
  contentType _ = "text/plain"
instance MimeRender RawText Text where
  mimeRender _ = fromStrict . Encoding.encodeUtf8
instance MimeUnrender RawText Text where
  mimeUnrender _ = pure . Encoding.decodeUtf8 . toStrict
instance MimeUnrender OctetStream Text where
  mimeUnrender _ = pure . Encoding.decodeUtf8 . toStrict

type Http2Golang =
       "reqinfo" :> Get '[RawText] Text
  :<|> "goroutines" :> StreamGet NewlineFraming RawText (ResultStream Text)
  :<|> "ECHO" :> ReqBody '[RawText] Text :> Put '[OctetStream] Text

myApi :: Proxy Http2Golang
myApi = Proxy

getExample :: H2ClientM Text
getGoroutines :: H2ClientM (ResultStream Text)
capitalize :: Text -> H2ClientM Text
getExample :<|> getGoroutines :<|> capitalize = h2client myApi

main :: IO ()
main = do
    frameConn <- newHttp2FrameConnection "http2.golang.org" 443 (Just tlsParams)
    client <- newHttp2Client frameConn 8192 8192 [] defaultGoAwayHandler ignoreFallbackHandler
    let env = H2ClientEnv "http2.golang.org" client
    runH2ClientM getExample env >>= print
    runH2ClientM (capitalize "shout me something back") env >>= print
    runH2ClientM getGoroutines env >>= go
  where
    go :: Either ServantError (ResultStream Text) -> IO ()
    go (Left err) = print err
    go (Right (ResultStream k)) = k $ \getResult ->
       let loop = do
            r <- getResult
            case r of
                Nothing -> return ()
                Just x -> print x >> loop
       in loop
    tlsParams = TLS.ClientParams {
          TLS.clientWantSessionResume    = Nothing
        , TLS.clientUseMaxFragmentLength = Nothing
        , TLS.clientServerIdentification = ("http2.golang.org", ByteString.pack "443")
        , TLS.clientUseServerNameIndication = True
        , TLS.clientShared               = def
        , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return []
                                               }
        , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
        , TLS.clientDebug                = def
        }
