{- git-annex command
 -
 - Copyright 2010-2013 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Command.Unannex where

import Command
import qualified Annex
import Annex.Content
import Annex.Perms
import qualified Git.Command
import Utility.CopyFile
import qualified Database.Keys
import Git.FilePath

cmd :: Command
cmd = withGlobalOptions [annexedMatchingOptions] $
	command "unannex" SectionUtility
		"undo accidental add command"
		paramPaths (withParams seek)

seek :: CmdParams -> CommandSeek
seek ps = (withFilesInGit $ commandAction . whenAnnexed start) =<< workTreeItems ps

start :: RawFilePath -> Key -> CommandStart
start file key = stopUnless (inAnnex key) $
	starting "unannex" (mkActionItem (key, file)) $
		perform (fromRawFilePath file) key

perform :: FilePath -> Key -> CommandPerform
perform file key = do
	liftIO $ removeFile file
	inRepo $ Git.Command.run
		[ Param "rm"
		, Param "--cached"
		, Param "--force"
		, Param "--quiet"
		, Param "--"
		, File file
		]
	next $ cleanup file key

cleanup :: FilePath -> Key -> CommandCleanup
cleanup file key = do
	Database.Keys.removeAssociatedFile key =<< inRepo (toTopFilePath file)
	src <- calcRepo $ gitAnnexLocation key
	ifM (Annex.getState Annex.fast)
		( do
			-- Only make a hard link if the annexed file does not
			-- already have other hard links pointing at it.
			-- This avoids unannexing (and uninit) ending up
			-- hard linking files together, which would be
			-- surprising.
			s <- liftIO $ getFileStatus src
			if linkCount s > 1
				then copyfrom src
				else hardlinkfrom src
		, copyfrom src
		)
  where
	copyfrom src = 
		thawContent file `after` liftIO (copyFileExternal CopyAllMetaData src file)
	hardlinkfrom src =
		-- creating a hard link could fall; fall back to copying
		ifM (liftIO $ catchBoolIO $ createLink src file >> return True)
			( return True
			, copyfrom src
			)
