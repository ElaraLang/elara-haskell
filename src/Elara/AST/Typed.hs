{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Elara.AST.Typed where

import Control.Lens hiding (List)
import Control.Lens.Extras (uniplate)
import Data.Data (Data)
import Elara.AST.Name (LowerAlphaName, ModuleName, Name, Qualified, TypeName, VarName)
import Elara.AST.Region (Located (Located), SourceRegion, generatedSourceRegion, unlocated)
import Elara.AST.StripLocation (StripLocation (stripLocation))
import Elara.AST.Unlocated.Typed qualified as Unlocated
import Elara.Data.Pretty
import Elara.Data.Unique
import Prelude hiding (Op)

{- | Typed AST Type
This is very similar to 'Elara.AST.Shunted.Expr' except:

- Everything has a type!
-}
data Expr' t
    = Int Integer
    | Float Double
    | String Text
    | Char Char
    | Unit
    | Var (Located (VarRef VarName))
    | Constructor (Located (VarRef TypeName))
    | Lambda (Located (Unique VarName)) (Expr t)
    | FunctionCall (Expr t) (Expr t)
    | If (Expr t) (Expr t) (Expr t)
    | List [Expr t]
    | Match (Expr t) [(Pattern t, Expr t)]
    | LetIn (Located (Unique VarName)) (Expr t) (Expr t)
    | Let (Located (Unique VarName)) (Expr t)
    | Block (NonEmpty (Expr t))
    | Tuple (NonEmpty (Expr t))
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

newtype Expr t = Expr (Located (Expr' t), t)
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

typeOf :: Expr t -> t
typeOf (Expr (_, t)) = t

data VarRef' c n
    = Global (c (Qualified n))
    | Local (c (Unique n))
    deriving (Functor)

deriving instance (Show (c (Qualified n)), Show (c (Unique n))) => Show (VarRef' c n)
deriving instance (Eq (c (Qualified n)), Eq (c (Unique n))) => Eq (VarRef' c n)
deriving instance (Typeable c, Typeable n, Data (c (Qualified n)), Data (c (Unique n))) => Data (VarRef' c n)

type VarRef n = VarRef' Located n

type UnlocatedVarRef n = VarRef' Identity n

data Pattern' t
    = VarPattern (Located (VarRef VarName))
    | ConstructorPattern (Located (Qualified TypeName)) [Pattern t]
    | ListPattern [Pattern t]
    | WildcardPattern
    | IntegerPattern Integer
    | FloatPattern Double
    | StringPattern Text
    | CharPattern Char
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

newtype Pattern t = Pattern (Located (Pattern' t), t)
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

data TypeAnnotation t = TypeAnnotation (Located (Qualified Name)) t
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

newtype Declaration t = Declaration (Located (Declaration' t))
    deriving (Show, Eq, Functor, Foldable, Traversable)

data Declaration' t = Declaration'
    { _declaration'Module' :: Located ModuleName
    , _declaration'Name :: Located (Qualified Name)
    , _declaration'Body :: DeclarationBody t
    }
    deriving (Show, Eq, Functor, Foldable, Traversable)

newtype DeclarationBody t = DeclarationBody (Located (DeclarationBody' t))
    deriving (Show, Eq, Functor, Foldable, Traversable)

data DeclarationBody' t
    = -- | def <name> : <type> and / or let <p> = <e>
      Value
        { _expression :: Expr t
        , _valueType :: Maybe (Located (TypeAnnotation t))
        }
    | -- | type <name> = <type>
      TypeAlias (Located t)
    deriving (Show, Eq, Functor, Foldable, Traversable)

makePrisms ''Declaration
makeLenses ''Declaration'
makePrisms ''DeclarationBody
makePrisms ''DeclarationBody'
makeLenses ''DeclarationBody
makeLenses ''DeclarationBody'
makePrisms ''Expr
makePrisms ''Expr'
makePrisms ''VarRef'
makePrisms ''Pattern

instance (Data t) => Plated (Expr t) where
    plate = uniplate

instance (Data t) => Plated (Expr' t) where
    plate = uniplate

instance (StripLocation t t') => StripLocation (Expr t) (Unlocated.Expr t') where
    stripLocation (Expr (e, t)) = Unlocated.Expr (stripLocation $ stripLocation e, stripLocation t)

instance (StripLocation t t') => StripLocation (Expr' t) (Unlocated.Expr' t') where
    stripLocation e = case e of
        Int i -> Unlocated.Int i
        Float f -> Unlocated.Float f
        String s -> Unlocated.String s
        Char c -> Unlocated.Char c
        Unit -> Unlocated.Unit
        Var lv -> Unlocated.Var (stripLocation $ stripLocation lv)
        Constructor q -> Unlocated.Constructor (stripLocation $ stripLocation q)
        Lambda (Located _ u) e' -> Unlocated.Lambda u (stripLocation e')
        FunctionCall e1 e2 -> Unlocated.FunctionCall (stripLocation e1) (stripLocation e2)
        If e1 e2 e3 -> Unlocated.If (stripLocation e1) (stripLocation e2) (stripLocation e3)
        List es -> Unlocated.List (stripLocation es)
        Match e' pes -> Unlocated.Match (stripLocation e') (stripLocation pes)
        LetIn (Located _ u) e1 e2 -> Unlocated.LetIn u (stripLocation e1) (stripLocation e2)
        Let (Located _ u) e' -> Unlocated.Let u (stripLocation e')
        Block es -> Unlocated.Block (stripLocation es)
        Tuple es -> Unlocated.Tuple (stripLocation es)

instance StripLocation (VarRef a) (Unlocated.VarRef a) where
    stripLocation v = case v of
        Global q -> Unlocated.Global (stripLocation q)
        Local u -> Unlocated.Local (stripLocation u)

instance (StripLocation t t') => StripLocation (Pattern t) (Unlocated.Pattern t') where
    stripLocation (Pattern (p, t)) = Unlocated.Pattern (stripLocation $ stripLocation p, stripLocation t)

instance (StripLocation t t') => StripLocation (Pattern' t) (Unlocated.Pattern' t') where
    stripLocation p = case p of
        VarPattern v -> Unlocated.VarPattern (stripLocation $ stripLocation v)
        ConstructorPattern q ps -> Unlocated.ConstructorPattern (stripLocation q) (stripLocation ps)
        WildcardPattern -> Unlocated.WildcardPattern
        IntegerPattern i -> Unlocated.IntegerPattern i
        FloatPattern f -> Unlocated.FloatPattern f
        StringPattern s -> Unlocated.StringPattern s
        CharPattern c -> Unlocated.CharPattern c
        ListPattern c -> Unlocated.ListPattern (stripLocation c)

-- Pretty Printing :D

instance (Pretty t', StripLocation t t', Pretty t) => Pretty (Declaration t) where
    pretty (Declaration ldb) = pretty ldb

instance (Pretty t', StripLocation t t', Pretty t) => Pretty (Declaration' t) where
    pretty (Declaration' _ n b) = prettyDB (n ^. unlocated) (b ^. _DeclarationBody . unlocated)

prettyDB :: (Pretty t', StripLocation t t', Pretty t) => Qualified Name -> DeclarationBody' t -> Doc ann
prettyDB name (Value e@(Expr (_, t)) Nothing) =
    prettyDB
        name
        (Value e (Just (Located (generatedSourceRegion Nothing) (TypeAnnotation (Located (generatedSourceRegion Nothing) name) t))))
prettyDB name (Value e (Just t)) =
    vsep
        [ "def" <+> pretty name <+> ":" <+> pretty t
        , "let" <+> pretty name <+> "="
        , indent indentDepth (pretty (e ^. _Expr . _1))
        , "" -- add a newline
        ]
prettyDB name (TypeAlias t) = "type" <+> pretty name <+> "=" <+> pretty t

instance (Pretty t', StripLocation t t') => Pretty (Expr t) where
    pretty e = pretty (stripLocation e)
instance (Pretty t', StripLocation t t') => Pretty (Expr' t) where
    pretty e = pretty (stripLocation e)

instance (Pretty t) => Pretty (TypeAnnotation t) where
    pretty (TypeAnnotation _ t) = pretty t

instance
    ( Pretty (q (Qualified a))
    , Pretty (q (Unique a))
    , Pretty a
    ) =>
    Pretty (VarRef' q a)
    where
    pretty (Global q) = pretty q
    pretty (Local q) = pretty q