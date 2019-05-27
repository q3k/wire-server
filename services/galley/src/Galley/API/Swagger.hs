{-# OPTIONS_GHC -Wno-orphans #-}

-- | swagger2 docs for galley generated with servant-swagger.  for now, this module contains
-- all of the servant code as well.
module Galley.API.Swagger where

import Imports

import "swagger2" Data.Swagger hiding (Header(..))
  -- NB: this package depends on both types-common, swagger2, so there is no away around this name
  -- clash other than -XPackageImports.

import Brig.Types.Provider
import Brig.Types.Team.LegalHold
import Control.Lens hiding (allOf)
import Data.Aeson
import Data.HashMap.Strict.InsOrd
import Data.Id
import Data.Misc
import Data.PEM
import Data.Proxy
import Data.String.Conversions (cs)
import Data.UUID
import Data.UUID (UUID)
import Servant.API hiding (Header)
import Servant.Swagger
import URI.ByteString.QQ (uri)

import qualified Data.Text as Text
import qualified Data.ByteString.Char8 as BS


-- TODO: document exceptions properly.

-- TODO: document zusr authentication thingy somehow.

-- TODO: factor out the servant handlers from the functions in Gally.API.LegalHold, and build
--       them together to an Application.  don't run it yet, but that would give us some extra
--       confidence that the swagger docs is in sync with the implementation.


swagger :: Swagger
swagger = toSwagger (Proxy @GalleyRoutes)


type GalleyRoutes = GalleyRoutesPublic :<|> GalleyRoutesInternal -- :<|> GalleyRoutesNotImplemented

type GalleyRoutesPublic
     = "teams" :> Capture "tid" TeamId :> "legalhold" :> "settings"
          :> ReqBody '[JSON] NewLegalHoldService :> Post '[JSON] ViewLegalHoldService
  :<|> "teams" :> Capture "tid" TeamId :> "legalhold" :> "settings"
          :> Get '[JSON] ViewLegalHoldService
  :<|> "teams" :> Capture "tid" TeamId :> "legalhold" :> "settings"
          :> Verb 'DELETE 204 '[] NoContent

type GalleyRoutesInternal
     = "i" :> "teams" :> Capture "tid" TeamId :> "legalhold"
          :> Get '[JSON] LegalHoldTeamConfig
  :<|> "i" :> "teams" :> Capture "tid" TeamId :> "legalhold"
          :> ReqBody '[JSON] LegalHoldTeamConfig
          :> Put '[] NoContent

{-
type GalleyRoutesNotImplemented
     = "teams" :> Capture "tid" TeamId :> "legalhold" :> Capture "uid" UserId
          :> ReqBody '[JSON] NewLegalHoldService :> Post '[JSON] ViewLegalHoldService
-}


instance ToParamSchema (Id a) where
    toParamSchema _ = toParamSchema (Proxy @UUID)

instance ToSchema (Id a) where
    declareNamedSchema _ = declareNamedSchema (Proxy @UUID)

instance ToSchema HttpsUrl where
    declareNamedSchema _ = declareNamedSchema (Proxy @Text)

instance ToSchema ServiceKeyPEM where
    declareNamedSchema _ = declareNamedSchema (Proxy @Text)

instance ToSchema (Fingerprint Rsa) where
    declareNamedSchema _ = declareNamedSchema (Proxy @Text)

instance ToSchema ServiceToken where
    declareNamedSchema _ = declareNamedSchema (Proxy @Text)

instance ToSchema NewLegalHoldService where
    declareNamedSchema _ = pure $ NamedSchema (Just "NewLegalHoldService") $ mempty
        & properties .~ properties_
        & example .~ example_
      where
        properties_ :: InsOrdHashMap Text (Referenced Schema)
        properties_ = fromList
          [ ("base_url", Inline (toSchema (Proxy @HttpsUrl)))
                -- Ref (Reference "HttpsUrl")  -- (ghc can't see if this reference is dangling or not)
          , ("public_key", Inline (toSchema (Proxy @ServiceKeyPEM)))
          , ("auth_token", Inline (toSchema (Proxy @ServiceToken)))
          ]

        example_ :: Maybe Value
        example_ = Just . toJSON
                 $ NewLegalHoldService lhuri (ServiceKeyPEM key) (ServiceToken "uUKFJdUcvYP")
          where
            Right lhuri = mkHttpsUrl [uri|https://example.com/|]
            Right [key] = pemParseBS . BS.unlines $
              [ "-----BEGIN PUBLIC KEY-----"
              , "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu+Kg/PHHU3atXrUbKnw0"
              , "G06FliXcNt3lMwl2os5twEDcPPFw/feGiAKymxp+7JqZDrseS5D9THGrW+OQRIPH"
              , "WvUBdiLfGrZqJO223DB6D8K2Su/odmnjZJ2z23rhXoEArTplu+Dg9K+c2LVeXTKV"
              , "VPOaOzgtAB21XKRiQ4ermqgi3/njr03rXyq/qNkuNd6tNcg+HAfGxfGvvCSYBfiS"
              , "bUKr/BeArYRcjzr/h5m1In6fG/if9GEI6m8dxHT9JbY53wiksowy6ajCuqskIFg8"
              , "7X883H+LA/d6X5CTiPv1VMxXdBUiGPuC9IT/6CNQ1/LFt0P37ax58+LGYlaFo7la"
              , "nQIDAQAB"
              , "-----END PUBLIC KEY-----"
              ]

instance ToSchema ViewLegalHoldService where
    declareNamedSchema _ = pure $ NamedSchema (Just "ViewLegalHoldService") $ mempty
        & properties .~ properties_
        & example .~ example_
      where
        properties_ :: InsOrdHashMap Text (Referenced Schema)
        properties_ = fromList
          [ ("team_id", Inline (toSchema (Proxy @TeamId)))
          , ("base_url", Inline (toSchema (Proxy @HttpsUrl)))
          , ("fingerprint", Inline (toSchema (Proxy @(Fingerprint Rsa))))
          ]

        example_ :: Maybe Value
        example_ = Just . toJSON
                 $ ViewLegalHoldService (Id tid) lhuri fpr
          where
            Just tid = fromText "7fff70c6-7b9c-11e9-9fbd-f3cc32e6bbec"
            Right lhuri = mkHttpsUrl [uri|https://example.com/|]
            fpr = Fingerprint "\138\140\183\EM\226#\129\EOTl\161\183\246\DLE\161\142\220\239&\171\241h|\\GF\172\180O\129\DC1!\159"

instance ToSchema LegalHoldTeamConfig where
    declareNamedSchema _ = pure $ NamedSchema (Just "LegalHoldTeamConfig") $ mempty
        & properties .~ properties_
        & example .~ example_
      where
        properties_ :: InsOrdHashMap Text (Referenced Schema)
        properties_ = fromList
          [ ("status", Inline (toSchema (Proxy @LegalHoldStatus)
              & description .~ Just (enumTextField (Proxy @LegalHoldStatus) <> "; " <>
                                     "determines whether admins of a team " <>
                                     "are allowed to enable LH for their users")))
          ]

        example_ :: Maybe Value
        example_ = Just . toJSON
                 $ LegalHoldTeamConfig LegalHoldDisabled

instance ToSchema LegalHoldStatus where
    declareNamedSchema _ = declareNamedSchema (Proxy @Text)

-- | TODO: find the idiomatic way to do this!
enumTextField :: (Bounded a, Enum a) => Proxy a -> Text
enumTextField Proxy = "one of " <>
    (Text.intercalate ", " $ cs . encode <$> [(minBound @LegalHoldStatus)..])


{-
-- import Data.String.Conversions
-- import System.Process (system)

-- | dump to file and validate online
--
-- TODO: this shouldn't be in the production code.
main :: IO ()
main = do
  writeFile "/tmp/x" . cs $ encode swagger
  void $ system "cat /tmp/x | json_pp && curl -X POST -d @/tmp/x -H 'Content-Type:application/json' http://online.swagger.io/validator/debug | json_pp"
  -- see also: https://github.com/swagger-api/validator-badge

  -- alternatives:
  -- https://github.com/navidsh/maven.swagger.validator
  -- https://editor.swagger.io/  (this finds dangling refs.  good.)
  -- https://apidevtools.org/swagger-parser/online/  (also finds dangling refs, but it's *very slow*)
-}
