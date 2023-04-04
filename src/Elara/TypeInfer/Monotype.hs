{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

{- | This module stores the `Monotype` type representing monomorphic types and
    utilites for operating on `Monotype`s
-}
module Elara.TypeInfer.Monotype (
  -- * Types
  Monotype (..),
  Scalar (..),
  Record (..),
  RemainingFields (..),
  Union (..),
  RemainingAlternatives (..),
) where

import Data.String (IsString (..))
import Data.Text (Text)
import Elara.Data.Pretty (Pretty (..))
import Elara.TypeInfer.Existential (Existential)
import GHC.Generics (Generic)

{- | A monomorphic type

    This is same type as `Grace.Type.Type`, except without the
    `Grace.Type.Forall` and `Grace.Type.Exists` constructors
-}
data Monotype
  = VariableType Text
  | UnsolvedType (Existential Monotype)
  | Function Monotype Monotype
  | Optional Monotype
  | List Monotype
  | Record Record
  | Union Union
  | Scalar Scalar
  | Tuple (NonEmpty Monotype)
  deriving (Eq, Generic, Show)

instance IsString Monotype where
  fromString string = VariableType (fromString string)

-- | A scalar type
data Scalar
  = -- | Boolean type
    --
    -- >>> pretty Bool
    -- Bool
    Bool
  | -- | Real number type
    --
    -- >>> pretty Real
    -- Real
    Real
  | -- | Integer number type
    --
    -- >>> pretty Integer
    -- Integer
    Integer
  | -- | Natural number type
    --
    -- >>> pretty Natural
    -- Natural
    Natural
  | -- | Text type
    --
    -- >>> pretty Text
    -- Text
    Text
  | -- | Char type
    --
    -- >>> pretty Char
    -- Char
    Char
  | -- | Unit type
    --
    -- >>> pretty Unit
    -- ()
    Unit
  deriving stock (Eq, Generic, Show)

instance Pretty Scalar where
  pretty Bool = "Bool"
  pretty Real = "Real"
  pretty Natural = "Natural"
  pretty Integer = "Integer"
  pretty Text = "Text"
  pretty Char = "Char"
  pretty Unit = "()"

-- | A monomorphic record type
data Record = Fields [(Text, Monotype)] RemainingFields
  deriving stock (Eq, Generic, Show)

-- | This represents whether or not the record type is open or closed
data RemainingFields
  = -- | The record type is closed, meaning that all fields are known
    EmptyFields
  | -- | The record type is open, meaning that some fields are known and there
    --   is an unsolved fields variable that is a placeholder for other fields
    --   that may or may not be present
    UnsolvedFields (Existential Record)
  | -- | Same as `UnsolvedFields`, except that the user has given the fields
    --   variable an explicit name in the source code
    VariableFields Text
  deriving stock (Eq, Generic, Show)

-- | A monomorphic union type
data Union = Alternatives [(Text, Monotype)] RemainingAlternatives
  deriving stock (Eq, Generic, Show)

-- | This represents whether or not the union type is open or closed
data RemainingAlternatives
  = -- | The union type is closed, meaning that all alternatives are known
    EmptyAlternatives
  | -- | The union type is open, meaning that some alternatives are known and
    --   there is an unsolved alternatives variable that is a placeholder for
    --   other alternatives that may or may not be present
    UnsolvedAlternatives (Existential Union)
  | -- | Same as `UnsolvedAlternatives`, except that the user has given the
    --   alternatives variable an explicit name in the source code
    VariableAlternatives Text
  deriving stock (Eq, Generic, Show)