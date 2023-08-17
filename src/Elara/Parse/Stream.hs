{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}

module Elara.Parse.Stream where

import Control.Lens
import Data.Text qualified as T
import Elara.AST.Region (HasPath (path), Located (Located), RealPosition (Position), RealSourceRegion, generatedFileName, generatedSourcePos, sourceRegion, startPos, unlocated, _RealSourceRegion)
import Elara.Lexer.Token
import Text.Megaparsec

data TokenStream = TokenStream
    { tokenStreamInput :: String
    , tokenStreamTokens :: [Lexeme]
    , tokenStreamIgnoringIndents :: Int
    -- ^ how many indent/dedent tokens to ignore, the "depth". In some cases, we don't care about indentation even when the lexer produces it
    -- for example, the list literal
    -- @[ 1
    --  , 2 ]@
    -- is technically indented, so the lexer produces an indent token after the 1
    -- Now, we don't care about this indent token, because we're not parsing a block, so there are 2 solutions:
    -- 1) Make the lexer context-sensitive so it only produces indentation when necessary, which is probably gonna be very unreliable
    -- 2) Filter out indentation tokens sometimes in the parser, which is what we're doing.
    -- When a structure doesn't care about indentation, like a list literal, it should increment 'tokenStreamIgnoringIndents' by 1 (or a higher amount if more indentation should be ignored)
    -- Then, when the parser encounters an indent token, if 'tokenStreamIgnoringIndents' is greater than 0, it should ignore the token.
    -- When the parser encounters a dedent token, it should decrement 'tokenStreamIgnoringIndents' by 1.
    -- This approach assumes that indents and dedents are always paired, which is a little naive but should be true as they are generated by the lexer
    -- Effectively, the parser pretends that indent & dedent tokens don't exist whenever this field is non-zero
    }
    deriving (Show)

pattern L :: a -> Located a
pattern L i <- Located _ i

instance Stream TokenStream where
    type Token TokenStream = Lexeme
    type Tokens TokenStream = [Lexeme]
    tokenToChunk Proxy x = [x]
    tokensToChunk Proxy xs = xs
    chunkToTokens Proxy = identity
    chunkLength Proxy = length
    chunkEmpty Proxy = null
    take1_ :: TokenStream -> Maybe (Text.Megaparsec.Token TokenStream, TokenStream)
    take1_ (TokenStream _ [] _) = Nothing
    take1_ (TokenStream str ((L TokenIndent) : ts) ii) | ii > 0 = take1_ (TokenStream str ts ii) -- ignore indent token
    take1_ (TokenStream str ((L TokenDedent) : ts) ii) | ii > 0 = take1_ (TokenStream str ts (ii - 1)) -- ignore dedent token and decrement depth
    take1_ (TokenStream str (t : ts) ii) = Just (t, TokenStream (drop (tokensLength (Proxy @TokenStream) (t :| [])) str) ts ii)
    takeN_ n (TokenStream str s ii)
        | n <= 0 = Just ([], TokenStream str s ii)
        | null s = Nothing
        | otherwise -- repeatedly call take1_ until it returns Nothing
            =
            let (x, s') = takeWhile_ (const True) (TokenStream str s ii)
             in case takeN_ (n - length x) s' of
                    Nothing -> Nothing
                    Just (xs, s'') -> Just (x ++ xs, s'')

    takeWhile_ f (TokenStream str s ii) =
        let (x, s') = span f s
         in case nonEmpty x of
                Nothing -> (x, TokenStream str s' ii)
                Just nex -> (x, TokenStream (drop (tokensLength (Proxy @TokenStream) nex) str) s' ii)

instance VisualStream TokenStream where
    showTokens Proxy =
        toString
            . T.intercalate " "
            . toList
            . fmap (tokenRepr . view unlocated)
    tokensLength Proxy xs = sum (tokenLength <$> xs)

instance TraversableStream TokenStream where
    reachOffset o PosState{..} =
        ( Just (prefix ++ restOfLine)
        , PosState
            { pstateInput =
                TokenStream
                    { tokenStreamInput = postStr
                    , tokenStreamTokens = postLexemes
                    , tokenStreamIgnoringIndents = 0
                    }
            , pstateOffset = max pstateOffset o
            , pstateSourcePos = newSourcePos
            , pstateTabWidth = pstateTabWidth
            , pstateLinePrefix = prefix
            }
        )
      where
        prefix =
            if sameLine
                then pstateLinePrefix ++ preLine
                else preLine
        sameLine = sourceLine newSourcePos == sourceLine pstateSourcePos
        newSourcePos =
            case postLexemes of
                [] -> pstateSourcePos
                (x : _) -> sourceRegionToSourcePos x sourceRegion startPos
        (preLexemes, postLexemes) = splitAt (o - pstateOffset) (tokenStreamTokens pstateInput)
        (preStr, postStr) = splitAt tokensConsumed (tokenStreamInput pstateInput)
        preLine = reverse . takeWhile (/= '\n') . reverse $ preStr
        tokensConsumed =
            case nonEmpty preLexemes of
                Nothing -> 0
                Just nePre -> tokensLength (Proxy @TokenStream) nePre
        restOfLine = takeWhile (/= '\n') postStr

sourceRegionToSourcePos :: (HasPath a1) => Located a2 -> Lens' (Located a2) a1 -> Lens' RealSourceRegion RealPosition -> SourcePos
sourceRegionToSourcePos sr l which = do
    let fp = view (l . path) sr
    case preview (sourceRegion . _RealSourceRegion . which) sr of
        Just pos -> realPositionToSourcePos fp pos
        Nothing -> generatedSourcePos fp

realPositionToSourcePos :: Maybe FilePath -> RealPosition -> SourcePos
realPositionToSourcePos fp (Position line column) =
    SourcePos
        { sourceName = fromMaybe generatedFileName fp
        , sourceLine = mkPos line
        , sourceColumn = mkPos column
        }

tokenLength :: Lexeme -> Int
tokenLength = T.length . tokenRepr . view unlocated
