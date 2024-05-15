module Test.Pipes.Node.FS where

import Prelude

import Control.Monad.Error.Class (catchError)
import Data.Foldable (fold, intercalate)
import Data.Newtype (wrap)
import Data.Tuple.Nested ((/\))
import Effect.Class (liftEffect)
import Node.Encoding (Encoding(..))
import Node.FS.Sync as FS
import Pipes (yield, (>->))
import Pipes.Core (runEffect) as Pipes
import Pipes.Node.Buffer as Pipes.Node.Buffer
import Pipes.Node.FS as Pipes.Node.FS
import Pipes.Node.Stream (inEOS, unEOS, withEOS)
import Pipes.Prelude (drain, map, toListM) as Pipes
import Pipes.String as Pipes.String
import Pipes.Util as Pipes.Util
import Simple.JSON (writeJSON)
import Test.Common (jsonParse, tmpFile, tmpFiles)
import Test.Spec (Spec, around, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

spec :: Spec Unit
spec = describe "Pipes.Node.FS" do
  describe "read" do
    around tmpFile $ it "fails if the file does not exist" \p -> do
      flip catchError (const $ pure unit) do
        Pipes.runEffect $ Pipes.Node.FS.read p >-> Pipes.drain
        fail "should have thrown"
    around tmpFile $ it "reads ok" \p -> do
      liftEffect $ FS.writeTextFile UTF8 p "foo"
      s <- fold <$> Pipes.toListM (Pipes.Node.FS.read p >-> unEOS >-> Pipes.Node.Buffer.toString UTF8)
      s `shouldEqual` "foo"
  describe "create" do
    around tmpFile $ it "creates the file when not exists" \p -> do
      Pipes.runEffect $ withEOS (yield "foo" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.create p
      contents <- liftEffect $ FS.readTextFile UTF8 p
      contents `shouldEqual` "foo"
    around tmpFile $ it "fails if the file already exists" \p -> do
      liftEffect $ FS.writeTextFile UTF8 p "foo"
      flip catchError (const $ pure unit) do
        Pipes.runEffect $ withEOS (yield "foo" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.create p
        fail "should have thrown"
  describe "append" do
    around tmpFile $ it "creates the file when not exists" \p -> do
      Pipes.runEffect $ withEOS (yield "foo" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.append p
      contents <- liftEffect $ FS.readTextFile UTF8 p
      contents `shouldEqual` "foo"
    around tmpFile $ it "appends" \p -> do
      Pipes.runEffect $ withEOS (yield "foo" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.append p
      Pipes.runEffect $ withEOS (yield "\n" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.append p
      Pipes.runEffect $ withEOS (yield "bar" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.append p
      contents <- liftEffect $ FS.readTextFile UTF8 p
      contents `shouldEqual` "foo\nbar"
  describe "trunc" do
    around tmpFile $ it "creates the file when not exists" \p -> do
      Pipes.runEffect $ withEOS (yield "foo" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.trunc p
      contents <- liftEffect $ FS.readTextFile UTF8 p
      contents `shouldEqual` "foo"
    around tmpFile $ it "overwrites contents" \p -> do
      Pipes.runEffect $ withEOS (yield "foo" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.trunc p
      Pipes.runEffect $ withEOS (yield "bar" >-> Pipes.Node.Buffer.fromString UTF8) >-> Pipes.Node.FS.trunc p
      contents <- liftEffect $ FS.readTextFile UTF8 p
      contents `shouldEqual` "bar"
  around tmpFiles $ it "json lines >-> parse >-> _.foo >-> write" \(a /\ b) -> do
    let
      exp = [ { foo: "a" }, { foo: "bar" }, { foo: "123" } ]
    liftEffect $ FS.writeTextFile UTF8 a $ intercalate "\n" $ writeJSON <$> exp
    Pipes.runEffect $
      Pipes.Node.FS.read a
        >-> inEOS (Pipes.Node.Buffer.toString UTF8)
        >-> Pipes.String.split (wrap "\n")
        >-> inEOS (jsonParse @{ foo :: String })
        >-> inEOS (Pipes.map _.foo)
        >-> Pipes.Util.intersperse "\n"
        >-> inEOS (Pipes.Node.Buffer.fromString UTF8)
        >-> Pipes.Node.FS.create b
    act <- liftEffect $ FS.readTextFile UTF8 b
    act `shouldEqual` "a\nbar\n123"
