{-# LANGUAGE CPP               #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports    #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}

module Ide.Plugin.Hlint
  (
    descriptor
  --, provider
  ) where
import Refact.Apply
import Control.Arrow ((&&&))
import Control.DeepSeq
import Control.Exception
import Control.Lens ((^.))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Aeson.Types (ToJSON(..), FromJSON(..), Value(..))
import Data.Binary
import Data.Hashable
import qualified Data.HashMap.Strict as Map
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Typeable
import Development.IDE
import Development.IDE.Core.Rules (defineNoFile)
import Development.IDE.Core.Shake (getDiagnostics)

#ifdef GHC_LIB
import Data.List (nub)
import "ghc-lib" GHC hiding (DynFlags(..))
import "ghc" GHC as RealGHC (DynFlags(..))
import "ghc" HscTypes as RealGHC.HscTypes (hsc_dflags)
import qualified "ghc" EnumSet as EnumSet
import Language.Haskell.GhclibParserEx.GHC.Driver.Session as GhclibParserEx (readExtension)
#else
import Development.IDE.GHC.Compat hiding (DynFlags(..))
#endif

import Ide.Logger
import Ide.Types
import Ide.Plugin.Config
import Ide.PluginUtils
import Language.Haskell.HLint as Hlint
import Language.Haskell.LSP.Core
import Language.Haskell.LSP.Types
import qualified Language.Haskell.LSP.Types      as LSP
import qualified Language.Haskell.LSP.Types.Lens as LSP
import System.FilePath (takeFileName)
import System.IO (hPutStr, noNewlineTranslation, hSetNewlineMode, utf8, hSetEncoding, IOMode(WriteMode), withFile, hClose)
import System.IO.Temp
import Text.Regex.TDFA.Text()
import GHC.Generics (Generic)

-- ---------------------------------------------------------------------

descriptor :: PluginId -> PluginDescriptor IdeState
descriptor plId = (defaultPluginDescriptor plId)
  { pluginRules = rules plId
  , pluginCommands =
      [ PluginCommand "applyOne" "Apply a single hint" applyOneCmd
      , PluginCommand "applyAll" "Apply all hints to the file" applyAllCmd
      ]
    , pluginCodeActionProvider = Just codeActionProvider
  }

-- This rule only exists for generating file diagnostics
-- so the RuleResult is empty
data GetHlintDiagnostics = GetHlintDiagnostics
    deriving (Eq, Show, Typeable, Generic)
instance Hashable GetHlintDiagnostics
instance NFData   GetHlintDiagnostics
instance Binary   GetHlintDiagnostics

type instance RuleResult GetHlintDiagnostics = ()

-- | Hlint rules to generate file diagnostics based on hlint hints
-- | This rule is recomputed when:
-- | - The files of interest have changed via `getFilesOfInterest`
-- | - One of those files has been edited via
-- |    - `getIdeas` -> `getParsedModule` in any case
-- |    - `getIdeas` -> `getFileContents` if the hls ghc does not match the hlint default ghc
-- | - The client settings have changed, to honour the `hlintOn` setting, via `getClientConfigAction`
-- | - The hlint specific settings have changed, via `getHlintSettingsRule`
rules :: PluginId -> Rules ()
rules plugin = do
  define $ \GetHlintDiagnostics file -> do
    config <- getClientConfigAction
    let pluginConfig = configForPlugin config plugin
    let hlintOn' = hlintOn config && pluginEnabled pluginConfig plcDiagnosticsOn
    ideas <- if hlintOn' then getIdeas file else return (Right [])
    return (diagnostics file ideas, Just ())

  getHlintSettingsRule (HlintEnabled [])

  action $ do
    files <- getFilesOfInterest
    void $ uses GetHlintDiagnostics $ Map.keys files

  where

      diagnostics :: NormalizedFilePath -> Either ParseError [Idea] -> [FileDiagnostic]
      diagnostics file (Right ideas) =
        [(file, ShowDiag, ideaToDiagnostic i) | i <- ideas, ideaSeverity i /= Ignore]
      diagnostics file (Left parseErr) =
        [(file, ShowDiag, parseErrorToDiagnostic parseErr)]

      ideaToDiagnostic :: Idea -> Diagnostic
      ideaToDiagnostic idea =
        LSP.Diagnostic {
            _range    = srcSpanToRange $ ideaSpan idea
          , _severity = Just LSP.DsInfo
          -- we are encoding the fact that idea has refactorings in diagnostic code
          , _code     = Just (LSP.StringValue $ T.pack $ codePre ++ ideaHint idea)
          , _source   = Just "hlint"
          , _message  = idea2Message idea
          , _relatedInformation = Nothing
          , _tags     = Nothing
        }
        where codePre = if null $ ideaRefactoring idea then "" else "refact:"

      idea2Message :: Idea -> T.Text
      idea2Message idea = T.unlines $ [T.pack $ ideaHint idea, "Found:", "  " <> T.pack (ideaFrom idea)]
                                     <> toIdea <> map (T.pack . show) (ideaNote idea)
        where
          toIdea :: [T.Text]
          toIdea = case ideaTo idea of
            Nothing -> []
            Just i  -> [T.pack "Why not:", T.pack $ "  " ++ i]


      parseErrorToDiagnostic :: ParseError -> Diagnostic
      parseErrorToDiagnostic (Hlint.ParseError l msg contents) =
        LSP.Diagnostic {
            _range    = srcSpanToRange l
          , _severity = Just LSP.DsInfo
          , _code     = Just (LSP.StringValue "parser")
          , _source   = Just "hlint"
          , _message  = T.unlines [T.pack msg,T.pack contents]
          , _relatedInformation = Nothing
          , _tags     = Nothing
        }

      -- This one is defined in Development.IDE.GHC.Error but here
      -- the types could come from ghc-lib or ghc
      srcSpanToRange :: SrcSpan -> LSP.Range
      srcSpanToRange (RealSrcSpan span) = Range {
          _start = LSP.Position {
                _line = srcSpanStartLine span - 1
              , _character  = srcSpanStartCol span - 1}
        , _end   = LSP.Position {
                _line = srcSpanEndLine span - 1
             , _character = srcSpanEndCol span - 1}
        }
      srcSpanToRange (UnhelpfulSpan _) = noRange

getIdeas :: NormalizedFilePath -> Action (Either ParseError [Idea])
getIdeas nfp = do
  logm $ "hlint:getIdeas:file:" ++ show nfp
  (flags, classify, hint) <- useNoFile_ GetHlintSettings

  let applyHints' (Just (Right modEx)) = Right $ applyHints classify hint [modEx]
      applyHints' (Just (Left err)) = Left err
      applyHints' Nothing = Right []

  fmap applyHints' (moduleEx flags)

  where moduleEx :: ParseFlags -> Action (Maybe (Either ParseError ModuleEx))
#ifdef GHC_LIB
        moduleEx flags = do
          mbpm <- getParsedModule nfp
          -- If ghc was not able to parse the module, we disable hlint diagnostics
          if isNothing mbpm
              then return Nothing
              else do
                     flags' <- setExtensions flags
                     (_, contents) <- getFileContents nfp
                     let fp = fromNormalizedFilePath nfp
                     let contents' = T.unpack <$> contents
                     Just <$> (liftIO $ parseModuleEx flags' fp contents')

        setExtensions flags = do
          hsc <- hscEnv <$> use_ GhcSession nfp
          let dflags = hsc_dflags hsc
          let hscExts = EnumSet.toList (extensionFlags dflags)
          let hscExts' = mapMaybe (GhclibParserEx.readExtension . show) hscExts
          let hlintExts = nub $ enabledExtensions flags ++ hscExts'
          logm $ "hlint:getIdeas:setExtensions:" ++ show hlintExts
          return $ flags { enabledExtensions = hlintExts }
#else
        moduleEx _flags = do
          mbpm <- getParsedModule nfp
          return $ createModule <$> mbpm
          where createModule pm = Right (createModuleEx anns modu)
                  where anns = pm_annotations pm
                        modu = pm_parsed_source pm
#endif

-- ---------------------------------------------------------------------

data HlintUsage
  = HlintEnabled { cmdArgs :: [String] }
  | HlintDisabled
  deriving Show

data GetHlintSettings = GetHlintSettings
    deriving (Eq, Show, Typeable, Generic)
instance Hashable GetHlintSettings
instance NFData   GetHlintSettings
instance NFData Hint where rnf = rwhnf
instance NFData Classify where rnf = rwhnf
instance NFData ParseFlags where rnf = rwhnf
instance Show Hint where show = const "<hint>"
instance Show ParseFlags where show = const "<parseFlags>"
instance Binary GetHlintSettings

type instance RuleResult GetHlintSettings = (ParseFlags, [Classify], Hint)

getHlintSettingsRule :: HlintUsage -> Rules ()
getHlintSettingsRule usage =
    defineNoFile $ \GetHlintSettings ->
      liftIO $ case usage of
          HlintEnabled cmdArgs -> argsSettings cmdArgs
          HlintDisabled -> fail "hlint configuration unspecified"

-- ---------------------------------------------------------------------

codeActionProvider :: CodeActionProvider IdeState
codeActionProvider _lf ideState plId docId _ context = Right . LSP.List . map CACodeAction <$> getCodeActions
  where

    getCodeActions = do
        applyOne <- applyOneActions
        diags <- getDiagnostics ideState
        let docNfp = toNormalizedFilePath' <$> uriToFilePath' (docId ^. LSP.uri)
            numHintsInDoc = length
              [d | (nfp, _, d) <- diags
                 , validCommand d
                 , Just nfp == docNfp
              ]
        -- We only want to show the applyAll code action if there is more than 1
        -- hint in the current document
        if numHintsInDoc > 1 then do
          applyAll <- applyAllAction
          pure $ applyAll:applyOne
        else
          pure applyOne

    applyAllAction = do
      let args = Just [toJSON (docId ^. LSP.uri)]
      cmd <- mkLspCommand plId "applyAll" "Apply all hints" args
      pure $ LSP.CodeAction "Apply all hints" (Just LSP.CodeActionQuickFix) Nothing Nothing (Just cmd)

    applyOneActions :: IO [LSP.CodeAction]
    applyOneActions = catMaybes <$> mapM mkHlintAction (filter validCommand diags)

    -- |Some hints do not have an associated refactoring
    validCommand (LSP.Diagnostic _ _ (Just (LSP.StringValue code)) (Just "hlint") _ _ _) =
        "refact:" `T.isPrefixOf` code
    validCommand _ =
        False

    LSP.List diags = context ^. LSP.diagnostics

    mkHlintAction :: LSP.Diagnostic -> IO (Maybe LSP.CodeAction)
    mkHlintAction diag@(LSP.Diagnostic (LSP.Range start _) _s (Just (LSP.StringValue code)) (Just "hlint") _ _ _) =
      Just . codeAction <$> mkLspCommand plId "applyOne" title (Just args)
     where
       codeAction cmd = LSP.CodeAction title (Just LSP.CodeActionQuickFix) (Just (LSP.List [diag])) Nothing (Just cmd)
       -- we have to recover the original ideaHint removing the prefix
       ideaHint = T.replace "refact:" "" code
       title = "Apply hint: " <> ideaHint
       -- need 'file', 'start_pos' and hint title (to distinguish between alternative suggestions at the same location)
       args = [toJSON (AOP (docId ^. LSP.uri) start ideaHint)]
    mkHlintAction (LSP.Diagnostic _r _s _c _source _m _ _) = return Nothing

-- ---------------------------------------------------------------------

applyAllCmd :: CommandFunction IdeState Uri
applyAllCmd lf ide uri = do
  let file = maybe (error $ show uri ++ " is not a file.")
                    toNormalizedFilePath'
                   (uriToFilePath' uri)
  withIndefiniteProgress lf "Applying all hints" Cancellable $ do
    logm $ "hlint:applyAllCmd:file=" ++ show file
    res <- applyHint ide file Nothing
    logm $ "hlint:applyAllCmd:res=" ++ show res
    return $
      case res of
        Left err -> (Left (responseError (T.pack $ "hlint:applyAll: " ++ show err)), Nothing)
        Right fs -> (Right Null, Just (WorkspaceApplyEdit, ApplyWorkspaceEditParams fs))

-- ---------------------------------------------------------------------

data ApplyOneParams = AOP
  { file      :: Uri
  , start_pos :: Position
  -- | There can be more than one hint suggested at the same position, so HintTitle is used to distinguish between them.
  , hintTitle :: HintTitle
  } deriving (Eq,Show,Generic,FromJSON,ToJSON)

type HintTitle = T.Text

data OneHint = OneHint
  { oneHintPos :: Position
  , oneHintTitle :: HintTitle
  } deriving (Eq, Show)

applyOneCmd :: CommandFunction IdeState ApplyOneParams
applyOneCmd lf ide (AOP uri pos title) = do
  let oneHint = OneHint pos title
  let file = maybe (error $ show uri ++ " is not a file.") toNormalizedFilePath'
                   (uriToFilePath' uri)
  let progTitle = "Applying hint: " <> title
  withIndefiniteProgress lf progTitle Cancellable $ do
    logm $ "hlint:applyOneCmd:file=" ++ show file
    res <- applyHint ide file (Just oneHint)
    logm $ "hlint:applyOneCmd:res=" ++ show res
    return $
      case res of
        Left err -> (Left (responseError (T.pack $ "hlint:applyOne: " ++ show err)), Nothing)
        Right fs -> (Right Null, Just (WorkspaceApplyEdit, ApplyWorkspaceEditParams fs))

applyHint :: IdeState -> NormalizedFilePath -> Maybe OneHint -> IO (Either String WorkspaceEdit)
applyHint ide nfp mhint =
  runExceptT $ do
    ideas <- bimapExceptT showParseError id $ ExceptT $ liftIO $ runAction "applyHint" ide $ getIdeas nfp
    let ideas' = maybe ideas (`filterIdeas` ideas) mhint
    let commands = map (show &&& ideaRefactoring) ideas'
    liftIO $ logm $ "applyHint:apply=" ++ show commands
    -- set Nothing as "position" for "applyRefactorings" because
    -- applyRefactorings expects the provided position to be _within_ the scope
    -- of each refactoring it will apply.
    -- But "Idea"s returned by HLint point to starting position of the expressions
    -- that contain refactorings, so they are often outside the refactorings' boundaries.
    -- Example:
    -- Given an expression "hlintTest = reid $ (myid ())"
    -- Hlint returns an idea at the position (1,13)
    -- That contains "Redundant brackets" refactoring at position (1,20):
    --
    -- [("src/App/Test.hs:5:13: Warning: Redundant bracket\nFound:\n  reid $ (myid ())\nWhy not:\n  reid $ myid ()\n",[Replace {rtype = Expr, pos = SrcSpan {startLine = 5, startCol = 20, endLine = 5, endCol = 29}, subts = [("x",SrcSpan {startLine = 5, startCol = 21, endLine = 5, endCol = 28})], orig = "x"}])]
    --
    -- If we provide "applyRefactorings" with "Just (1,13)" then
    -- the "Redundant bracket" hint will never be executed
    -- because SrcSpan (1,20,??,??) doesn't contain position (1,13).
    let fp = fromNormalizedFilePath nfp
    (_, mbOldContent) <- liftIO $ runAction "hlint" ide $ getFileContents nfp
    oldContent <- maybe (liftIO $ T.readFile fp) return mbOldContent
    -- We need to save a file with last edited contents cause `apply-refact`
    -- doesn't expose a function taking directly contents instead a file path.
    -- Ideally we should try to expose that function upstream and remove this.
    res <- liftIO $ withSystemTempFile (takeFileName fp) $ \temp h -> do
            hClose h
            writeFileUTF8NoNewLineTranslation temp oldContent
            (Right <$> applyRefactorings Nothing commands temp) `catches`
                    [ Handler $ \e -> return (Left (show (e :: IOException)))
                    , Handler $ \e -> return (Left (show (e :: ErrorCall)))
                    ]
    case res of
      Right appliedFile -> do
        let uri = fromNormalizedUri (filePathToUri' nfp)
        let wsEdit = diffText' True (uri, oldContent) (T.pack appliedFile) IncludeDeletions
        liftIO $ logm $ "hlint:applyHint:diff=" ++ show wsEdit
        ExceptT $ return (Right wsEdit)
      Left err ->
        throwE (show err)
    where
          -- | If we are only interested in applying a particular hint then
          -- let's filter out all the irrelevant ideas
          filterIdeas :: OneHint -> [Idea] -> [Idea]
          filterIdeas (OneHint (Position l c) title) ideas =
            let title' = T.unpack title
                ideaPos = (srcSpanStartLine &&& srcSpanStartCol) . toRealSrcSpan . ideaSpan
            in filter (\i -> ideaHint i == title' && ideaPos i == (l+1, c+1)) ideas

          toRealSrcSpan (RealSrcSpan real) = real
          toRealSrcSpan (UnhelpfulSpan x) = error $ "No real source span: " ++ show x

          showParseError :: Hlint.ParseError -> String
          showParseError (Hlint.ParseError location message content) =
            unlines [show location, message, content]

-- | Map over both failure and success.
bimapExceptT :: Functor m => (e -> f) -> (a -> b) -> ExceptT e m a -> ExceptT f m b
bimapExceptT f g (ExceptT m) = ExceptT (fmap h m) where
  h (Left e)  = Left (f e)
  h (Right a) = Right (g a)
{-# INLINE bimapExceptT #-}

writeFileUTF8NoNewLineTranslation :: FilePath -> T.Text -> IO()
writeFileUTF8NoNewLineTranslation file txt =
  withFile file WriteMode $ \h -> do
    hSetEncoding h utf8
    hSetNewlineMode h noNewlineTranslation
    hPutStr h (T.unpack txt)
