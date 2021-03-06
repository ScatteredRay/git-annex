{- git-annex command
 -
 - Copyright 2014 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Command.Undo where

import Command
import Git.DiffTree
import Git.FilePath
import Git.UpdateIndex
import Git.Sha
import qualified Git.LsFiles as LsFiles
import qualified Git.Command as Git
import qualified Git.Branch
import qualified Command.Sync
import qualified Utility.RawFilePath as R

cmd :: Command
cmd = notBareRepo $
	command "undo" SectionCommon 
		"undo last change to a file or directory"
		paramPaths (withParams seek)

seek :: CmdParams -> CommandSeek
seek ps = do
	-- Safety first; avoid any undo that would touch files that are not
	-- in the index.
	(fs, cleanup) <- inRepo $ LsFiles.notInRepo [] False (map toRawFilePath ps)
	unless (null fs) $
		giveup $ "Cannot undo changes to files that are not checked into git: " ++ unwords (map fromRawFilePath fs)
	void $ liftIO $ cleanup

	-- Committing staged changes before undo allows later
	-- undoing the undo. It would be nicer to only commit staged
	-- changes to the specified files, rather than all staged changes.
	void $ Command.Sync.commitStaged Git.Branch.ManualCommit
		"commit before undo"
	
	withStrings (commandAction . start) ps

start :: FilePath -> CommandStart
start p = starting "undo" ai si $
	perform p
  where
	ai = ActionItemOther (Just p)
	si = SeekInput [p]

perform :: FilePath -> CommandPerform
perform p = do
	g <- gitRepo

	-- Get the reversed diff that needs to be applied to undo.
	(diff, cleanup) <- inRepo $
		diffLog [Param "-R", Param "--", Param p]
	top <- inRepo $ toTopFilePath $ toRawFilePath p
	let diff' = filter (`isDiffOf` top) diff
	liftIO $ streamUpdateIndex g (map stageDiffTreeItem diff')

	-- Take two passes through the diff, first doing any removals,
	-- and then any adds. This order is necessary to handle eg, removing
	-- a directory and replacing it with a file.
	let (removals, adds) = partition (\di -> dstsha di `elem` nullShas) diff'
	let mkrel di = liftIO $ relPathCwdToFile $
		fromTopFilePath (file di) g

	forM_ removals $ \di -> do
		f <- mkrel di
		liftIO $ removeWhenExistsWith R.removeLink f

	forM_ adds $ \di -> do
		f <- fromRawFilePath <$> mkrel di
		inRepo $ Git.run [Param "checkout", Param "--", File f]

	next $ liftIO cleanup
