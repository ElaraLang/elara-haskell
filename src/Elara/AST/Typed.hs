{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Elara.AST.Typed where

import Control.Lens hiding (List)
import Control.Lens.Extras (uniplate)
import Data.Data (Data)
import Elara.AST.Name (ModuleName, Name, Qualified, TypeName, VarName)
import Elara.AST.Region (Located (Located), unlocated)
import Elara.AST.StripLocation (StripLocation (stripLocation))
import Elara.AST.Unlocated.Typed qualified as Unlocated
import Elara.Data.Pretty
import Elara.Data.Unique
import Prelude hiding (Op)

data PartialType = Id UniqueId | Partial (Type' PartialType) | Final Type
    deriving (Show, Eq, Ord, Data)

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
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

newtype Expr t = Expr (Located (Expr' t), t)
    deriving (Show, Eq, Data, Functor, Foldable, Traversable)

data VarRef n
    = Global (Located (Qualified n))
    | Local (Located (Unique n))
    deriving (Show, Eq, Ord, Functor, Data)

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
    deriving (Show, Eq, Data)

data Type' t
    = TypeVar TypeVar
    | FunctionType t t
    | UnitType
    | TypeConstructorApplication t t
    | UserDefinedType (Located (Qualified TypeName))
    | RecordType (NonEmpty (Located VarName, t))
    deriving (Show, Eq, Ord, Functor, Foldable, Traversable, Data)

newtype Type = Type (Type' Type)
    deriving (Show, Eq, Ord, Data)

newtype TypeVar = TyVar (Unique Text)
    deriving (Show, Eq, Ord, Data)

newtype Declaration t = Declaration (Located (Declaration' t))
    deriving (Show, Eq)

data Declaration' t = Declaration'
    { _declaration'Module' :: Located ModuleName
    , _declaration'Name :: Located (Qualified Name)
    , _declaration'Body :: DeclarationBody t
    }
    deriving (Show, Eq)

newtype DeclarationBody t = DeclarationBody (Located (DeclarationBody' t))
    deriving (Show, Eq)

data DeclarationBody' t
    = -- | def <name> : <type> and / or let <p> = <e>
      Value
        { _expression :: Expr t
        , _valueType :: Maybe (Located (TypeAnnotation t))
        }
    | NativeDef (Located (TypeAnnotation t))
    | -- | type <name> = <type>
      TypeAlias (Located Type)
    deriving (Show, Eq)

makePrisms ''Declaration
makeLenses ''Declaration'
makePrisms ''DeclarationBody
makePrisms ''DeclarationBody'
makeLenses ''DeclarationBody
makeLenses ''DeclarationBody'
makePrisms ''Expr
makePrisms ''Expr'
makePrisms ''VarRef
makePrisms ''PartialType
makePrisms ''Pattern

instance Data t => Plated (Expr t) where
    plate = uniplate

instance Data t => Plated (Expr' t) where
    plate = uniplate

instance StripLocation Type Unlocated.Type where
    stripLocation (Type t) = Unlocated.Type (stripLocation t)

instance StripLocation t t' => StripLocation (Type' t) (Unlocated.Type' t') where
    stripLocation t = case t of
        TypeVar (TyVar u) -> Unlocated.TypeVar (Unlocated.TyVar u)
        FunctionType t1 t2 -> Unlocated.FunctionType (stripLocation t1) (stripLocation t2)
        UnitType -> Unlocated.UnitType
        TypeConstructorApplication t1 t2 -> Unlocated.TypeConstructorApplication (stripLocation t1) (stripLocation t2)
        UserDefinedType (Located _ q) -> Unlocated.UserDefinedType q
        RecordType fields -> Unlocated.RecordType (stripLocation fields)

instance StripLocation t t' => StripLocation (Expr t) (Unlocated.Expr t') where
    stripLocation (Expr (e, t)) = Unlocated.Expr (stripLocation $ stripLocation e, stripLocation t)

instance StripLocation t t' => StripLocation (Expr' t) (Unlocated.Expr' t') where
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

instance StripLocation (VarRef a) (Unlocated.VarRef a) where
    stripLocation v = case v of
        Global (Located _ q) -> Unlocated.Global q
        Local (Located _ u) -> Unlocated.Local u

instance StripLocation t t' => StripLocation (Pattern t) (Unlocated.Pattern t') where
    stripLocation (Pattern (p, t)) = Unlocated.Pattern (stripLocation $ stripLocation p, stripLocation t)

instance StripLocation t t' => StripLocation (Pattern' t) (Unlocated.Pattern' t') where
    stripLocation p = case p of
        VarPattern v -> Unlocated.VarPattern (stripLocation $ stripLocation v)
        ConstructorPattern q ps -> Unlocated.ConstructorPattern (stripLocation q) (stripLocation ps)
        WildcardPattern -> Unlocated.WildcardPattern
        IntegerPattern i -> Unlocated.IntegerPattern i
        FloatPattern f -> Unlocated.FloatPattern f
        StringPattern s -> Unlocated.StringPattern s
        CharPattern c -> Unlocated.CharPattern c
        ListPattern c -> Unlocated.ListPattern (stripLocation c)

instance StripLocation PartialType Unlocated.PartialType where
    stripLocation (Id t) = Unlocated.Id t
    stripLocation (Final t) = Unlocated.Final (stripLocation t)
    stripLocation (Partial t) = Unlocated.Partial (stripLocation t)

instance Pretty PartialType where
    pretty (Id t) = pretty t
    pretty p = pretty (stripLocation p)

instance Pretty n => Pretty (VarRef n) where
    pretty (Global q) = pretty q
    pretty (Local q) = pretty q