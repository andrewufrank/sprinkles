{-#LANGUAGE DeriveGeneric #-}
{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE OverloadedLists #-}
{-#LANGUAGE LambdaCase #-}
{-#LANGUAGE ScopedTypeVariables #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE MultiParamTypeClasses #-}
module Web.Sprinkles.Handlers.Respond
( respondTemplateHtml
, respondTemplateText
)
where

import ClassyPrelude hiding (Builder)
import Web.Sprinkles.Backends
import qualified Network.Wai as Wai
import Web.Sprinkles.Logger as Logger
import Web.Sprinkles.Project
import Web.Sprinkles.ProjectConfig
import Web.Sprinkles.Exceptions
import Web.Sprinkles.TemplateContext

import Text.Ginger
       (parseGinger, Template, runGingerT, GingerContext, GVal(..), ToGVal(..),
        (~>))
import qualified Text.Ginger as Ginger
import Text.Ginger.Html (Html, htmlSource)

import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy.UTF8 as LUTF8
import Data.ByteString.Builder (stringUtf8, Builder)
import qualified Data.Yaml as YAML
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Encode.Pretty as JSON
import Data.Default (Default, def)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Locale.Read (getLocale)
import qualified Text.Pandoc as Pandoc
import qualified Text.Pandoc.Readers.Creole as Pandoc
import qualified Data.CaseInsensitive as CI

import Network.HTTP.Types
       (Status, status200, status302, status400, status404, status500)
import Network.HTTP.Types.URI (queryToQueryText)

import Web.Sprinkles.Backends.Loader.Type
       (PostBodySource (..), pbsFromRequest, pbsInvalid)

instance ToGVal m ByteString where
    toGVal = toGVal . UTF8.toString

instance ToGVal m (CI.CI ByteString) where
    toGVal = toGVal . CI.original

respondTemplateHtml :: ToGVal (Ginger.Run IO Html) a
                    => Project
                    -> Status
                    -> Text
                    -> HashMap Text a
                    -> Wai.Application
respondTemplateHtml =
    respondTemplate
        contentType
        writeText
        makeContext
    where
        contentType = "text/html;charset=utf8"
        writeText write = write . stringUtf8 . unpack . htmlSource
        makeContext = Ginger.makeContextHtmlM

respondTemplateText :: ToGVal (Ginger.Run IO Text) a
                    => Project
                    -> Status
                    -> Text
                    -> HashMap Text a
                    -> Wai.Application
respondTemplateText =
    respondTemplate
        contentType
        writeText
        makeContext
    where
        contentType = "text/plain;charset=utf8"
        writeText write = write . stringUtf8 . unpack . ClassyPrelude.asText
        makeContext = Ginger.makeContextTextM

respondTemplate :: ToGVal (Ginger.Run IO h) a
                => ToGVal (Ginger.Run IO h) h
                => Monoid h
                => ByteString -- ^ content type
                -> ( (Builder -> IO ())
                   -> h -> IO ()
                   )
                -> (  (Text -> Ginger.Run IO h (GVal (Ginger.Run IO h)))
                   -> (h -> IO ())
                   -> GingerContext IO h
                   )
                -> Project
                -> Status
                -> Text
                -> HashMap Text a
                -> Wai.Application
respondTemplate contentType
                writeText
                makeContext
                project
                status
                templateName
                contextMap
                request
                respond = do
    let contextLookup = mkContextLookup request project contextMap
        headers = [("Content-type", contentType)]
    template <- getTemplate project templateName
    respond . Wai.responseStream status headers $ \write flush -> do
        let context = makeContext contextLookup (writeText write)
        runGingerT context template
        flush

mkContextLookup :: (ToGVal (Ginger.Run IO h) a)
                => Wai.Request
                -> Project
                -> HashMap Text a
                -> Text
                -> Ginger.Run IO h (GVal (Ginger.Run IO h))
mkContextLookup request project contextMap key = do
    let cache = projectBackendCache project
        logger = projectLogger project
        contextMap' =
            fmap toGVal contextMap <>
            sprinklesGingerContext cache request logger
    return . fromMaybe def $ lookup key contextMap'

