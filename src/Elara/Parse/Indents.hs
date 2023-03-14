module Elara.Parse.Indents where

import Elara.AST.Frontend (Expr (..), Expr' (Block))

import Control.Lens (mapped, over, view, (^.))
import Elara.AST.Region (Located (..), sourceRegion)
import Elara.AST.Region qualified as Region (spanningRegion')
import Elara.Lexer.Token (Token (..))
import Elara.Parse.Combinators (sepBy1')
import Elara.Parse.Primitives (HParser, Parser, token')
import HeadedMegaparsec qualified as H
import Text.Megaparsec (MonadParsec (try), Pos, mkPos, pos1, unPos)
import Text.Megaparsec.Char.Lexer qualified as L

block :: HParser Expr -> HParser Expr
block exprParser = do
    token' TokenLeftBrace
    exprs <- sepBy1' exprParser (token' TokenSemicolon)
    token' TokenRightBrace
    pure $ merge exprs
  where
    merge :: NonEmpty Expr -> Expr
    merge expressions = case expressions of
        single :| [] -> single
        x :| xs -> do
            let unwrap (Expr e) = e
            let expressions' = unwrap <$> (x :| xs)
            let region = Region.spanningRegion' (view sourceRegion <$> expressions')
            let asBlock = \case
                    single :| [] -> Expr single
                    o -> Expr (Located region (Block $ Expr <$> o))
            asBlock expressions'