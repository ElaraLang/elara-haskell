{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}

module Main (
  main,
) where

import Elara.AST.Module
import Elara.AST.Select
import Elara.Error
import Elara.Error.Codes qualified as Codes (fileReadError)
import Elara.Lexer.Reader
import Elara.Lexer.Token (Lexeme)
import Elara.Lexer.Utils
import Elara.Parse
import Elara.Parse.Stream
import Error.Diagnose (Diagnostic, Report (Err), defaultStyle, printDiagnostic)
import Polysemy (Embed, Member, Sem, embed, runM)
import Polysemy.Maybe (MaybeE, justE, nothingE, runMaybe)
import Print (printColored)
import Prelude hiding (State, evalState, execState, modify, runReader, runState)
import Elara.Desugar (desugar, runDesugar)

main :: IO ()
main = do
  s <- runElara
  whenJust s $ \s' -> do
    printDiagnostic stdout True True 4 defaultStyle s'

runElara :: IO (Maybe (Diagnostic Text))
runElara = runM $ runMaybe $ execDiagnosticWriter $ do
  s <- loadModule "source.elr"
  p <- loadModule "prelude.elr"
  case liftA2 (,) s p of
    Nothing -> pass
    Just (source, prelude) -> do
      case runDesugar (desugar source) of
        Left err -> report err
        Right desugared -> embed (printColored desugared)

-- runElara :: IO (Diagnostic Text)
-- runElara = runM $ execDiagnosticWriter $ do
--   s <- loadModule "source.elr"
--   p <- loadModule "prelude.elr"
--   case liftA2 (,) s p of
--     Nothing -> pass
--     Just (source, prelude) ->
--       embed (printColored source)

--  case run $ runError $ runReader modules (annotateModule source) of
--     Left annotateError -> report annotateError
--     Right m' -> do
--       fixOperatorsInModule m' >>= embed . printColored
--  case run $ runError $ runReader modules (annotateModule source) of
--     Left annotateError -> report annotateError
--     Right m' -> do
--       fixOperatorsInModule m' >>= embed . printColored

-- fixOperatorsInModule :: (Member (DiagnosticWriter Text) r) => Module Annotated -> Sem r (Maybe (Module Annotated))
-- fixOperatorsInModule m = do
--   let x =
--         run $
--           runError $
--             runWriter $
--               overExpressions
--                 ( fixOperators
--                     ( fromList
--                         []
--                     )
--                 )
--                 m
--   case x of
--     Left shuntErr -> do
--       report shuntErr $> Nothing
--     Right (warnings, finalM) -> do
--       traverse_ report (toList warnings)
--       pure (Just finalM)

readFileString :: (Member (Embed IO) r, Member (DiagnosticWriter Text) r, Member MaybeE r) => FilePath -> Sem r String
readFileString path = do
  contentsBS <- readFileBS path
  case decodeUtf8Strict contentsBS of
    Left err -> do
      writeReport (Err (Just Codes.fileReadError) ("Could not read " <> toText path <> ": " <> show err) [] []) *> nothingE
    Right contents -> do
      addFile path contents
      justE contents

lexFile :: (Member (Embed IO) r, Member (DiagnosticWriter Text) r, Member MaybeE r) => FilePath -> Sem r (String, [Lexeme])
lexFile path = do
  contents <- readFileString path
  case evalLexMonad path contents readTokens of
    Left err -> report err *> nothingE
    Right lexemes ->
      justE (contents, lexemes)

loadModule :: (Member (Embed IO) r, Member (DiagnosticWriter Text) r, Member MaybeE r) => FilePath -> Sem r (Maybe (Module Frontend))
loadModule path = do
  (contents, lexemes) <- lexFile path
  let tokenStream = TokenStream contents lexemes
  case parse path tokenStream of
    Left parseError -> do
      report parseError $> Nothing
    Right m -> pure (Just m)

-- overExpressions = declarations . traverse . _Declaration . unlocated . declaration'Body . _DeclarationBody . unlocated . expression