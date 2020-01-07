{- git-update-index library
 -
 - Copyright 2011-2019 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE BangPatterns, OverloadedStrings, CPP #-}

module Git.UpdateIndex (
	Streamer,
	pureStreamer,
	streamUpdateIndex,
	streamUpdateIndex',
	startUpdateIndex,
	stopUpdateIndex,
	lsTree,
	lsSubTree,
	updateIndexLine,
	stageFile,
	unstageFile,
	stageSymlink,
	stageDiffTreeItem,
	refreshIndex,
) where

import Common
import Git
import Git.Types
import Git.Command
import Git.FilePath
import Git.Sha
import qualified Git.DiffTreeItem as Diff

import qualified Data.ByteString.Lazy as L

{- Streamers are passed a callback and should feed it lines in the form
 - read by update-index, and generated by ls-tree. -}
type Streamer = (L.ByteString -> IO ()) -> IO ()

{- A streamer with a precalculated value. -}
pureStreamer :: L.ByteString -> Streamer
pureStreamer !s = \streamer -> streamer s

{- Streams content into update-index from a list of Streamers. -}
streamUpdateIndex :: Repo -> [Streamer] -> IO ()
streamUpdateIndex repo as = bracket (startUpdateIndex repo) stopUpdateIndex $
	(\h -> forM_ as $ streamUpdateIndex' h)

data UpdateIndexHandle = UpdateIndexHandle ProcessHandle Handle

streamUpdateIndex' :: UpdateIndexHandle -> Streamer -> IO ()
streamUpdateIndex' (UpdateIndexHandle _ h) a = a $ \s -> do
	L.hPutStr h s
	L.hPutStr h "\0"

startUpdateIndex :: Repo -> IO UpdateIndexHandle
startUpdateIndex repo = do
	(Just h, _, _, p) <- createProcess (gitCreateProcess params repo)
		{ std_in = CreatePipe }
	return $ UpdateIndexHandle p h
  where
	params = map Param ["update-index", "-z", "--index-info"]

stopUpdateIndex :: UpdateIndexHandle -> IO Bool
stopUpdateIndex (UpdateIndexHandle p h) = do
	hClose h
	checkSuccessProcess p

{- A streamer that adds the current tree for a ref. Useful for eg, copying
 - and modifying branches. -}
lsTree :: Ref -> Repo -> Streamer
lsTree (Ref x) repo streamer = do
	(s, cleanup) <- pipeNullSplit params repo
	mapM_ streamer s
	void $ cleanup
  where
	params = map Param ["ls-tree", "-z", "-r", "--full-tree", x]
lsSubTree :: Ref -> FilePath -> Repo -> Streamer
lsSubTree (Ref x) p repo streamer = do
	(s, cleanup) <- pipeNullSplit params repo
	mapM_ streamer s
	void $ cleanup
  where
	params = map Param ["ls-tree", "-z", "-r", "--full-tree", x, p]

{- Generates a line suitable to be fed into update-index, to add
 - a given file with a given sha. -}
updateIndexLine :: Sha -> TreeItemType -> TopFilePath -> L.ByteString
updateIndexLine sha treeitemtype file = L.fromStrict $
	fmtTreeItemType treeitemtype
	<> " blob "
	<> encodeBS (fromRef sha)
	<> "\t"
	<> indexPath file

stageFile :: Sha -> TreeItemType -> FilePath -> Repo -> IO Streamer
stageFile sha treeitemtype file repo = do
	p <- toTopFilePath (toRawFilePath file) repo
	return $ pureStreamer $ updateIndexLine sha treeitemtype p

{- A streamer that removes a file from the index. -}
unstageFile :: FilePath -> Repo -> IO Streamer
unstageFile file repo = do
	p <- toTopFilePath (toRawFilePath file) repo
	return $ unstageFile' p

unstageFile' :: TopFilePath -> Streamer
unstageFile' p = pureStreamer $ L.fromStrict $
	"0 "
	<> encodeBS' (fromRef deleteSha)
	<> "\t"
	<> indexPath p

{- A streamer that adds a symlink to the index. -}
stageSymlink :: FilePath -> Sha -> Repo -> IO Streamer
stageSymlink file sha repo = do
	!line <- updateIndexLine
		<$> pure sha
		<*> pure TreeSymlink
		<*> toTopFilePath (toRawFilePath file) repo
	return $ pureStreamer line

{- A streamer that applies a DiffTreeItem to the index. -}
stageDiffTreeItem :: Diff.DiffTreeItem -> Streamer
stageDiffTreeItem d = case toTreeItemType (Diff.dstmode d) of
	Nothing -> unstageFile' (Diff.file d)
	Just t -> pureStreamer $ updateIndexLine (Diff.dstsha d) t (Diff.file d)

indexPath :: TopFilePath -> InternalGitPath
indexPath = toInternalGitPath . getTopFilePath

{- Refreshes the index, by checking file stat information.  -}
refreshIndex :: Repo -> ((FilePath -> IO ()) -> IO ()) -> IO Bool
refreshIndex repo feeder = do
	(Just h, _, _, p) <- createProcess (gitCreateProcess params repo)
		{ std_in = CreatePipe }
	feeder $ \f -> do
		hPutStr h f
		hPutStr h "\0"
	hFlush h
	hClose h
	checkSuccessProcess p
  where
	params = 
		[ Param "update-index"
		, Param "-q"
		, Param "--refresh"
		, Param "-z"
		, Param "--stdin"
		]
