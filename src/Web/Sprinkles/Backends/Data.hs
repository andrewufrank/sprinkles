{-#LANGUAGE NoImplicitPrelude #-}
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE TypeFamilies #-}
{-#LANGUAGE MultiParamTypeClasses #-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE LambdaCase #-}
{-#LANGUAGE DeriveGeneric #-}

-- | Types for and operations on backend data.
module Web.Sprinkles.Backends.Data
( BackendData (..)
, BackendMeta (..)
, BackendSource (..)
, toBackendData
, Items (..)
, reduceItems
, addBackendDataChildren
)
where

import ClassyPrelude
import Text.Ginger (ToGVal (..), GVal, Run (..), dict, (~>))
import qualified Text.Ginger as Ginger
import Data.Aeson as JSON
import Data.Aeson.TH as JSON
import Data.Yaml as YAML
import qualified Data.Serialize as Cereal
import Data.Serialize (Serialize)
import Foreign.C.Types (CTime (..))
import Network.Mime (MimeType)
import Data.Default (Default (..))
import Data.Time.Clock.POSIX (POSIXTime, posixSecondsToUTCTime)
import Data.Time (UTCTime, LocalTime, utc, utcToLocalTime)
import Data.Scientific (Scientific)

import Web.Sprinkles.Backends.Spec

-- | Extract raw integer value from a 'CTime'
unCTime :: CTime -> Int
unCTime (CTime i) = fromIntegral i

-- | The shapes of data that can be returned from a backend query.
data Items a = NotFound -- ^ Nothing was found
             | SingleItem a -- ^ A single item was requested, and this is it
             | MultiItem [a] -- ^ Multiple items were requested, here they are

-- | Transform a raw list of results into an 'Items' value. This allows us
-- later to distinguish between Nothing Found vs. Empty List, and between
-- Single Item Requested And Found vs. Many Items Requested, One Found. This
-- is needed such that when a single item is requested, it gets converted to
-- 'GVal' and JSON as a scalar, while when we request many items and receive
-- one, it becomes a singleton list.
reduceItems :: FetchMode -> [a] -> Items a
reduceItems FetchOne [] = NotFound
reduceItems FetchOne (x:_) = SingleItem x
reduceItems FetchAll xs = MultiItem xs
reduceItems (FetchN n) xs = MultiItem $ take n xs

instance ToGVal m a => ToGVal m (Items a) where
    toGVal NotFound = def
    toGVal (SingleItem x) = toGVal x
    toGVal (MultiItem xs) = toGVal xs

instance ToJSON a => ToJSON (Items a) where
    toJSON NotFound = Null
    toJSON (SingleItem x) = toJSON x
    toJSON (MultiItem xs) = toJSON xs

-- | A parsed record from a query result.
data BackendData m h =
    BackendData
        { bdJSON :: JSON.Value -- ^ Result body as JSON
        , bdGVal :: GVal (Run m h) -- ^ Result body as GVal
        , bdRaw :: LByteString -- ^ Raw result body source
        , bdMeta :: BackendMeta -- ^ Meta-information
        , bdChildren :: HashMap Text (BackendData m h) -- ^ Child documents
        }

-- | A raw (unparsed) record from a query result.
data BackendSource =
    BackendSource
        { bsMeta :: BackendMeta
        , bsSource :: LByteString
        }
        deriving (Generic)

instance Serialize BackendSource where

-- | Wrap a parsed backend value in a 'BackendData' structure. The original
-- raw 'BackendSource' value is needed alongside the parsed value, because the
-- resulting structure contains both the 'BackendMeta' and the raw (unparsed)
-- data from it.
toBackendData :: (ToJSON a, ToGVal (Run m h) a) => BackendSource -> a -> BackendData m h
toBackendData src val =
    BackendData
        { bdJSON = toJSON val
        , bdGVal = toGVal val
        , bdRaw = bsSource src
        , bdMeta = bsMeta src
        , bdChildren = mapFromList []
        }

addBackendDataChildren :: HashMap Text (BackendData m h)
                       -> BackendData m h
                       -> BackendData m h
addBackendDataChildren children bd =
    bd { bdChildren = children <> bdChildren bd }

instance ToJSON (BackendData m h) where
    toJSON = bdJSON

instance ToGVal (Run m h) (BackendData m h) where
    toGVal bd =
        let baseVal = bdGVal bd
            baseLookup = fromMaybe (const def) $ Ginger.asLookup baseVal
            baseDictItems = Ginger.asDictItems baseVal
            children = bdChildren bd
            childrenG = toGVal children
        in baseVal
            { Ginger.asLookup = Just $ \case
                "props" -> return . toGVal . bdMeta $ bd
                "children" -> return childrenG
                k -> baseLookup k
            , Ginger.asDictItems =
                (("props" ~> bdMeta bd):) .
                (("children", childrenG):) <$> baseDictItems
            }

-- | Metadata for a backend query result.
data BackendMeta =
    BackendMeta
        { bmMimeType :: MimeType
        , bmMTime :: Maybe POSIXTime -- ^ Last modification time, if available
        , bmName :: Text -- ^ Human-friendly name
        , bmPath :: Text -- ^ Path, according to the semantics of the backend (file path or URI)
        , bmSize :: Maybe Integer -- ^ Size of the raw source, in bytes, if available
        }
        deriving (Show, Generic)

instance Serialize BackendMeta where
    put bm = do
        Cereal.put $ bmMimeType bm
        Cereal.put . fmap fromEnum $ bmMTime bm
        Cereal.put . encodeUtf8 $ bmName bm
        Cereal.put . encodeUtf8 $ bmPath bm
        Cereal.put $ bmSize bm
    get =
        BackendMeta <$> Cereal.get
                    <*> (fmap toEnum <$> Cereal.get)
                    <*> (decodeUtf8 <$> Cereal.get)
                    <*> (decodeUtf8 <$> Cereal.get)
                    <*> Cereal.get

mtimeFlavors :: BackendMeta -> (Maybe POSIXTime, Maybe Scientific, Maybe LocalTime)
mtimeFlavors bm =
    let mtime = bmMTime bm
    in ( mtime
       , realToFrac <$> mtime :: Maybe Scientific
       , utcToLocalTime utc . posixSecondsToUTCTime <$> mtime
       )

instance ToJSON BackendMeta where
    toJSON bm =
        let (mtime, mtimeSci, mtimeUTC) = mtimeFlavors bm
        in JSON.object
            [ "mimeType" .= decodeUtf8 (bmMimeType bm)
            , "mtime" .= mtimeSci
            , "mtimeUTC" .= mtimeUTC
            , "name" .= bmName bm
            , "path" .= bmPath bm
            , "size" .= bmSize bm
            ]

instance ToGVal m BackendMeta where
    toGVal bm =
        let (mtime, mtimeSci, mtimeUTC) = mtimeFlavors bm
        in Ginger.dict
            [ "type" ~> decodeUtf8 (bmMimeType bm)
            , "mtime" ~> mtimeSci
            , "mtimeUTC" ~> mtimeUTC
            , "name" ~> bmName bm
            , "path" ~> bmPath bm
            , "size" ~> bmSize bm
            ]

