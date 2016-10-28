{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE TypeFamilies #-}
{-#LANGUAGE MultiParamTypeClasses #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE LambdaCase #-}

-- | Backend loader type
module Web.Sprinkles.Backends.Loader.Type
where

import ClassyPrelude
import qualified Network.Wai as Wai

import Web.Sprinkles.Backends.Data
        ( BackendData (..)
        , BackendMeta (..)
        , BackendSource (..)
        , Items (..)
        , reduceItems
        )
import Web.Sprinkles.Backends.Spec
        ( FetchMode (..)
        , FetchOrder (..)
        )
import Web.Sprinkles.Logger (LogLevel)

data PostBodySource =
    PostBodySource
        { loadPost :: IO LByteString
        , contentType :: ByteString
        }

type Loader = (LogLevel -> Text -> IO ())
            -> PostBodySource
            -> FetchMode
            -> FetchOrder
            -> IO [BackendSource]

pbsFromRequest :: Wai.Request -> PostBodySource
pbsFromRequest request =
    PostBodySource
        { loadPost = Wai.lazyRequestBody request
        , contentType = fromMaybe "text/plain" $
            lookup "Content-type" (Wai.requestHeaders request)
        }

pbsInvalid :: PostBodySource
pbsInvalid =
    PostBodySource
        { loadPost = fail "POST body not available"
        , contentType = "text/plain"
        }
