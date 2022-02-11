module Lib
  ( someFunc,
  )
where

import Control.Monad (forM_)
import Data.List (intercalate)
import Interpreter.Execute
import Interpreter.State
import Parse.AST
import Parse.Parser
import Parse.Reader
import Parse.Utils

someFunc :: IO ()
someFunc = do
  content <- readFile "source.elr"
  let tokens = evalP readTokens content
  print tokens
  let codeLines = parse content
  env <- initialEnvironment
  forM_ codeLines $ \(ExpressionL ast) -> do
    execute ast env

showASTNode :: Expression -> String
showASTNode (FuncApplicationE a b) = showASTNode a ++ " " ++ showASTNode b
showASTNode (LetE pattern value) = "let " ++ showPattern pattern ++ " = " ++ showASTNode value
showASTNode (IdentifierE i) = showIdentifier i
showASTNode (ConstE val) = showConst val
showASTNode (BlockE expressions) = "{" ++ (intercalate "; " $ map showASTNode expressions) ++ "}"
showASTNode (InfixApplicationE op a b) = showASTNode a ++ " " ++ showIdentifier op ++ " " ++ showASTNode b
showASTNode (ListE expressions) = "[" ++ (intercalate ", " $ map showASTNode expressions) ++ "]"
showASTNode (IfElseE condition thenBranch elseBranch) = "if " ++ showASTNode condition ++ " then " ++ showASTNode thenBranch ++ " else " ++ showASTNode elseBranch

showConst :: Constant -> String
showConst (StringC s) = s
showConst (IntC i) = show i

showIdentifier (NormalIdentifier i) = i
showIdentifier (OpIdentifier i) = i

showPattern (IdentifierP p) = showIdentifier p
