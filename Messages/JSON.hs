{- git-annex command-line JSON output and input
 -
 - Copyright 2011-2016 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE OverloadedStrings #-}

module Messages.JSON (
	start,
	end,
	note,
	add,
	complete,
	progress,
	DualDisp(..),
	ObjectMap(..),
	JSONActionItem(..),
) where

import Data.Aeson
import Control.Applicative
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as B
import System.IO
import Data.Maybe
import Data.Monoid
import Prelude

import qualified Utility.JSONStream as Stream
import Types.Key
import Utility.Metered
import Utility.Percentage

start :: String -> Maybe FilePath -> Maybe Key -> IO ()
start command file key = B.hPut stdout $ Stream.start $ Stream.AesonObject o
  where
	Object o = toJSON $ JSONActionItem
		{ itemCommand = Just command
		, itemKey = key
		, itemFile = file
		, itemAdded = Nothing
		}

end :: Bool -> IO ()
end b = B.hPut stdout $ Stream.add (Stream.JSONChunk [("success", b)]) `B.append` Stream.end

note :: String -> IO ()
note s = add (Stream.JSONChunk [("note", s)])

add :: Stream.JSONChunk a -> IO ()
add = B.hPut stdout . Stream.add

complete :: Stream.JSONChunk a -> IO ()
complete v = B.hPut stdout $ Stream.start v `B.append` Stream.end

progress :: IO () -> Integer -> BytesProcessed -> IO ()
progress jsonbuffer size bytesprocessed = do
	B.hPut stdout $ Stream.start $ Stream.AesonObject o
	putStr ",\"action\":"
	jsonbuffer
	B.hPut stdout $ Stream.end
	B.hPut stdout $ Stream.end
  where
	n = fromBytesProcessed bytesprocessed :: Integer
	Object o = object
		[ "byte-progress" .= n
		, "percent-progress" .= showPercentage 2 (percentage size n)
		]

-- A value that can be displayed either normally, or as JSON.
data DualDisp = DualDisp
	{ dispNormal :: String
	, dispJson :: String
	}

instance ToJSON DualDisp where
	toJSON = toJSON . dispJson

instance Show DualDisp where
	show = dispNormal

-- A Map that is serialized to JSON as an object, with each key being a
-- field of the object. This is different from Aeson's normal 
-- serialization of Map, which uses "[key, value]".
data ObjectMap a = ObjectMap { fromObjectMap :: M.Map String a }

instance ToJSON a => ToJSON (ObjectMap a) where
	toJSON (ObjectMap m) = object $ map go $ M.toList m
	  where
		go (k, v) = (T.pack k, toJSON v)

-- An item that a git-annex command acts on, and displays a JSON object about.
data JSONActionItem a = JSONActionItem
	{ itemCommand :: Maybe String
	, itemKey :: Maybe Key
	, itemFile :: Maybe FilePath
	, itemAdded :: Maybe a -- for additional fields added by `add`
	}
	deriving (Show)

instance ToJSON (JSONActionItem a) where
	toJSON i = object $ catMaybes
		[ Just $ "command" .= itemCommand i
		, case itemKey i of
			Nothing -> Nothing
			Just k -> Just $ "key" .= toJSON k
		, Just $ "file" .= itemFile i
		-- itemAdded is not included; must be added later by 'add'
		]

instance FromJSON a => FromJSON (JSONActionItem a) where
	parseJSON (Object v) = JSONActionItem
		<$> (v .:? "command")
		<*> (maybe (return Nothing) parseJSON =<< (v .:? "key"))
		<*> (v .:? "file")
		<*> parseadded
	  where
		parseadded = (Just <$> parseJSON (Object v)) <|> return Nothing
	parseJSON _ = mempty
