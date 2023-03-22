{
-- | Lexer for the Elara language.
-- | This module is generated by Alex.
-- | See https://www.haskell.org/alex/   
-- | Credit to https://ice1000.org/2020/06-20-LayoutLexerInAlex.html and https://serokell.io/blog/lexing-with-alex for the inspiration
module Elara.Lexer.Lexer where

import Elara.Lexer.Token
import Elara.Lexer.Utils
import Data.List.NonEmpty ((<|))
import Elara.AST.Region
import Control.Lens ((^.))

import Prelude hiding (ByteString)
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.ByteString.Lazy.Char8 qualified as BS
import Relude.Unsafe (read)
}

%wrapper "monadUserState-bytestring"

$whitechar = [\t\n\r\v\f\ ]
$white_no_nl = $white # \n 
$special   = [\(\)\,\;\[\]\{\}]

$digit = [0-9]
$hexit = [0-9a-fA-F]
$octit = [0-7]


$lower = [a-z]
$upper = [A-Z]
$identifierChar = [$lower $upper $digit]
$opChar = [\! \# \$ \% \& \* \+ \. \/ \\ \< \> \= \? \@ \^ \| \- \~]


@reservedid = match|class|data|default|type|if|else|then|let|in

@reservedOp = ".." | ":" | "::" | "="

@variableIdentifier  = $lower $identifierChar*
@typeIdentifier  = $upper $identifierChar*

@decimal     = $digit+
@octal       = $octit+
@hexadecimal = $hexit+
@exponent    = [eE] [\-\+] @decimal

@string = [^\"]
@notNewline = .

Elara :-
    -- Inside string literals
    <string> {
        \" { exitString `andBegin` 0 }
        \\\\ { addStringChar '\\' }
        \\\" { addStringChar '"' }
        \\n  { addStringChar '\n' }
        \\t  { addStringChar '\t' }
        .    { addCurrentStringChar }
    }

    -- Layout Rules
    <layout> {
        \n ;
        \{ { explicitBraceLeft }
        () { newLayoutContext }
    }


    <0> {
        $white_no_nl       ;
        \n { beginCode beginOfLines }

        -- Literals
        \-? @decimal 
            | 0[o0] @octal
            | 0[xX] @hexadecimal
        { parametrizedTok TokenInt (read . toString) }

        \-? @decimal . @decimal
        { parametrizedTok TokenFloat parseFloat }

        \" { enterString `andBegin` string }

        -- Symbols 
        \; { emptyTok TokenSemicolon }
        \, { emptyTok TokenComma }
        \. { emptyTok TokenDot }
        \: { emptyTok TokenColon }
        \= { emptyTok TokenEquals }
        \\ { emptyTok TokenBackslash }
        \-\> { emptyTok TokenRightArrow }
        \<\- { emptyTok TokenLeftArrow }
        \=\> { emptyTok TokenDoubleRightArrow }
        \@ { emptyTok TokenAt }
        \( { emptyTok TokenLeftParen }
        \) { emptyTok TokenRightParen }
        \[ { emptyTok TokenLeftBracket }
        \] { emptyTok TokenRightBracket }
        \{ { emptyTok TokenLeftBrace }
        \} { emptyTok TokenRightBrace }


        -- Keywords
        def { emptyTok TokenDef }
        let { emptyTok TokenLet }
        in { emptyTok TokenIn }
        if { emptyTok TokenIf }
        then { emptyTok TokenThen }
        else { emptyTok TokenElse }
        class { emptyTok TokenClass }
        data { emptyTok TokenData }
        type { emptyTok TokenType }
        module { emptyTok TokenModule }
        match { emptyTok TokenMatch}
        with { emptyTok TokenWith }


        -- Identifiers
        @variableIdentifier { parametrizedTok TokenVariableIdentifier id }
        @typeIdentifier { parametrizedTok TokenConstructorIdentifier id }
        $opChar+ { parametrizedTok TokenOperatorIdentifier id }
    }


  

    <beginOfLines> {
        \n ;
        () { doBeginOfLines }
    }

{

data LayoutType =
    NoLayout -- ^ No layout, analogous to the <0> rule
    | Layout !Int
    deriving (Show)

data AlexUserState = AlexUserState {
    fileName :: FilePath,
    strStart :: AlexPosn,
    strBuffer :: [Char], 
    layoutStack :: [LayoutType],
    alexStartCodes :: [Int]
} deriving (Show)

alexInitUserState :: AlexUserState
alexInitUserState = AlexUserState {
    fileName = "",
    strStart = AlexPn 0 0 0,
    strBuffer = [],
    layoutStack = [],
    alexStartCodes = [0]
}

getA :: Alex AlexUserState
getA = Alex $ \s -> Right (s, alex_ust s)

putA :: AlexUserState -> Alex ()
putA s' = Alex $ \s -> Right (s{alex_ust = s'}, ())

modifyA :: (AlexUserState -> AlexUserState) -> Alex ()
modifyA f = Alex $ \s -> Right (s{alex_ust = f (alex_ust s)}, ())

alexGetFilename :: Alex FilePath
alexGetFilename = fileName <$> getA

alexGetPos :: Alex AlexPosn
alexGetPos = Alex $ \s -> Right (s, alex_pos s)

alexInitFilename :: String -> Alex ()
alexInitFilename fname = modifyA (\s -> s{fileName = fname})

alexEOF :: Alex Lexeme
alexEOF = getLayout >>= \case
    Nothing         -> createEmptyLexeme TokenEOF
    Just (Layout _) -> popLayout >> createEmptyLexeme TokenRightBrace
    Just  NoLayout  -> popLayout >> alexMonadScan
  where
    createEmptyLexeme token = do
       (pn, _, _, _) <- alexGetInput
       createLexeme pn 0 token

type Lexeme = Located Token

emptyTok = mkL . const

parametrizedTok :: (a -> Token) -> (Text -> a) -> AlexInput -> Int64 -> Alex Lexeme
parametrizedTok toktype f = mkL (toktype . f)

mkL :: (Text -> Token) -> AlexInput -> Int64 -> Alex Lexeme
mkL toktype inp@(alexStartPos,_,str,_) len = do
    mkLConst toktype (decodeUtf8 $ BS.take len str) inp

mkLConst :: (Text -> Token) -> Text -> AlexInput -> Alex Lexeme
mkLConst toktype src (alexStartPos, _, _, _) = do
    alexEndPos <- alexGetPos
    mkLConstPos toktype src alexStartPos alexEndPos

mkLConstPos :: (Text -> Token) -> Text -> AlexPosn -> AlexPosn -> Alex Lexeme
mkLConstPos toktype src alexStartPos alexEndPos = do
    fname <- alexGetFilename
    let AlexPn _ startLine startCol = alexStartPos
        AlexPn _ endLine endCol = alexEndPos
        startPos = Position startLine startCol
        endPos   = Position endLine endCol
        srcSpan  = SourceRegion (Just fname) startPos endPos
        token = toktype src
    startNew <- startsNewLayout token <$> getLexState
    when startNew (pushLexState layout)
    pure $ Located (RealSourceRegion srcSpan) token

mkTokenPure :: AlexPosn -> Int -> (Text -> Token) -> Text -> Alex Lexeme
mkTokenPure alexStartPos len toktype src = do
    alexEndPos <- alexGetPos
    mkLConstPos toktype src alexStartPos alexEndPos

currentPosition :: AlexPosn -> Int -> Alex RealSourceRegion
currentPosition (AlexPn pos line col) size = do
  file <- fileName <$> getA
  let start = Position line col
  let end   = Position line (col + size)
  pure $ SourceRegion (Just file) start end

createLexeme :: AlexPosn -> Int -> Token -> Alex Lexeme
createLexeme alexStartPos len tok = do
  pos <- currentPosition alexStartPos len
  pure $ Located (RealSourceRegion pos) tok



-- Strings

enterString :: AlexAction Lexeme 
enterString inp@(pos, _, _, _) len = do
  modifyA $ \s -> s{strStart = pos, strBuffer = []}
  skip inp len

exitString inp@(pos, _, _, _) len = do
  s <- getA
  putA s{strStart = AlexPn 0 0 0, strBuffer = []} -- reset
  mkLConstPos TokenString (toText $ reverse $ strBuffer s) (strStart s) (alexMove pos '"')

addStringChar :: Char -> AlexAction Lexeme
addStringChar c inp@(pos, _, _, _) len = do
  s <- getA
  putA s{strBuffer = c : strBuffer s}
  skip inp len

addCurrentStringChar :: AlexAction Lexeme
addCurrentStringChar inp@(_, _, str, _) len = do
  modifyA $ \s -> s{strBuffer = BS.head str : strBuffer s}
  skip inp len

-- Indentation / Layout

beginCode :: Int -> AlexAction Lexeme
beginCode n _ _ = pushLexState n *> alexMonadScan

pushLexState :: Int -> Alex ()
pushLexState nsc = do
  sc <- alexGetStartCode
  s@AlexUserState { alexStartCodes = scs } <- getA
  putA s { alexStartCodes = sc : scs }
  alexSetStartCode nsc

popLexState :: Alex Int
popLexState = do
  csc <- alexGetStartCode
  s@AlexUserState { alexStartCodes = scs } <- getA
  case scs of
    []        -> alexError "State code expected but no state code available"
    sc : scs' -> do
      putA s { alexStartCodes = scs' }
      alexSetStartCode sc
      pure csc

getLexState :: Alex Int
getLexState = do
  AlexUserState { alexStartCodes = scs } <- getA
  case scs of
    []        -> alexError "State code expected but no state code available"
    sc : _scs' -> pure sc

popLayout :: Alex LayoutType
popLayout = do
  s@AlexUserState { layoutStack = lcs } <- getA
  case lcs of
    []        -> alexError "Layout expected but no layout available"
    lc : lcs' -> do
      putA s { layoutStack = lcs' }
      pure lc

pushLayout :: LayoutType -> Alex ()
pushLayout lc = do
  s@AlexUserState { layoutStack = lcs } <- getA
  putA s { layoutStack = lc : lcs }

getLayout :: Alex (Maybe LayoutType)
getLayout = do
  AlexUserState { layoutStack = lcs } <- getA
  pure $ listToMaybe lcs

explicitBraceLeft :: AlexAction Lexeme
explicitBraceLeft inp@((AlexPn pos line col), _, _, _) size = do
  popLexState
  pushLayout NoLayout
  mkLConst (const TokenLeftBrace) "" inp 

newLayoutContext :: AlexAction Lexeme
newLayoutContext inp@((AlexPn _ _ col), _, _, _) size = do
  popLexState
  pushLayout (Layout col)
  mkLConst (const TokenLeftBrace) "" inp


doBeginOfLines :: AlexAction Lexeme
doBeginOfLines (pn@(AlexPn _ _ col), _, _, _) size =
  getLayout >>= \case
    Just (Layout n) -> case col `compare` n of
      LT -> popLayout   *> addToken TokenRightBrace
      EQ -> popLexState *> addToken TokenSemicolon
      GT -> popLexState *> alexMonadScan
    _ -> popLexState *> alexMonadScan
  where addToken = createLexeme pn (fromIntegral size)

-- Frontend

lex :: FilePath -> ByteString -> Either String [Lexeme]
lex fname input = runAlex input $ alexInitFilename fname >> init <$> alexLex

alexLex :: Alex (NonEmpty Lexeme)
alexLex = do 
    lexeme <- alexMonadScan
    if lexeme ^. unlocated == TokenEOF
    then pure (lexeme :| [])
    else (lexeme <|) <$> alexLex
}