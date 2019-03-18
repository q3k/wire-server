{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}

-- | 'zauth' token signing and verification.
module Data.ZAuth.Settings
    ( -- * Monad
      ZAuth
    , MonadZAuth (..)
    , runZAuth

      -- * Env
    , Env
    , mkEnv
    , readKeys

      -- * Settings
    , settings
    , Settings (..)
    , localSettings
    , keyIndex
    , UserTokenTimeout (..)
    , userTokenTimeout
    , SessionTokenTimeout (..)
    , sessionTokenTimeout
    , AccessTokenTimeout (..)
    , accessTokenTimeout
    , ProviderTokenTimeout (..)
    , providerTokenTimeout

      -- * Token Creation
    , UserToken
    , AccessToken
    , ProviderToken
    , BotToken
    , mkUserToken
    , newUserToken
    , newSessionToken
    , newAccessToken
    , newProviderToken
    , newBotToken
    , renewAccessToken

      -- * Token Validation
    , validateToken
    , ZV.Failure (..)

      -- * Token Inspection
    , accessTokenOf
    , userTokenOf
    , userTokenRand
    , tokenExpires
    , tokenExpiresUTC
    , tokenKeyIndex

      -- * Re-exports
    , SecretKey
    , PublicKey
    ) where

import Imports
import Control.Lens ((^.), makeLenses, over)
import Data.Aeson
import Data.Bits
import Data.ByteString.Conversion.To
import Data.Id
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.ZAuth.Token
import OpenSSL.Random
import Sodium.Crypto.Sign

import qualified Data.ByteString       as BS
import qualified Data.List.NonEmpty    as NonEmpty
import qualified Data.ZAuth.Creation   as ZC
import qualified Data.ZAuth.Validation as ZV

#ifdef WITH_CQL
import Data.Coerce
import Database.CQL.Protocol hiding (header)
#endif

newtype ZAuth a = ZAuth { unZAuth :: ReaderT Env IO a }
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader Env)

class MonadIO m => MonadZAuth m where
    liftZAuth :: ZAuth a -> m a

instance MonadZAuth ZAuth where
    liftZAuth = id

runZAuth :: MonadIO m => Env -> ZAuth a -> m a
runZAuth e za = liftIO $ runReaderT (unZAuth za) e

data Settings = Settings
    { _keyIndex             :: !Int                   -- ^ Secret key index to use
                                                      --   for token creation
    , _userTokenTimeout     :: !UserTokenTimeout      -- ^ User token validity timeout
    , _sessionTokenTimeout  :: !SessionTokenTimeout   -- ^ Session token validity timeout
    , _accessTokenTimeout   :: !AccessTokenTimeout    -- ^ Access token validity timeout
    , _providerTokenTimeout :: !ProviderTokenTimeout  -- ^ Provider token validity timeout
    } deriving (Show, Eq, Generic)

data Env = Env
    { _private  :: !ZC.Env
    , _public   :: !ZV.Env
    , _settings :: !Settings
    }

type AccessToken   = Token Access
type UserToken     = Token User
type ProviderToken = Token Provider
type BotToken      = Token Bot

newtype UserTokenTimeout = UserTokenTimeout
    { userTokenTimeoutSeconds :: Integer }
    deriving (Show, Eq, Generic)

newtype SessionTokenTimeout = SessionTokenTimeout
    { sessionTokenTimeoutSeconds :: Integer }
    deriving (Show, Eq, Generic)

newtype AccessTokenTimeout = AccessTokenTimeout
    { accessTokenTimeoutSeconds :: Integer }
    deriving (Show, Eq, Generic)

newtype ProviderTokenTimeout = ProviderTokenTimeout
    { providerTokenTimeoutSeconds :: Integer }
    deriving (Show, Eq, Generic)

instance FromJSON UserTokenTimeout
instance FromJSON SessionTokenTimeout
instance FromJSON AccessTokenTimeout
instance FromJSON ProviderTokenTimeout

#ifdef WITH_CQL
-- | These helpers work with any newtype over Integer
toInt64 :: Coercible a Integer => a -> Int64
toInt64 n = fromInteger . clamp . coerce $ n
  where
    -- Don't overflow; just clamp
    clamp :: Integer -> Integer
    clamp = min (toInteger $ maxBound @Int64)

fromInt64 :: Coercible Integer a => Int64 -> a
fromInt64 = coerce . toInteger

instance Cql UserTokenTimeout where
  ctype = Tagged BigIntColumn
  toCql = CqlBigInt . toInt64
  fromCql (CqlBigInt i) = Right (fromInt64 i)
  fromCql _             = Left "Expected CqlBigInt."

instance Cql SessionTokenTimeout where
  ctype = Tagged BigIntColumn
  toCql = CqlBigInt . toInt64
  fromCql (CqlBigInt i) = Right (fromInt64 i)
  fromCql _             = Left "Expected CqlBigInt."

instance Cql AccessTokenTimeout where
  ctype = Tagged BigIntColumn
  toCql = CqlBigInt . toInt64
  fromCql (CqlBigInt i) = Right (fromInt64 i)
  fromCql _             = Left "Expected CqlBigInt."

instance Cql ProviderTokenTimeout where
  ctype = Tagged BigIntColumn
  toCql = CqlBigInt . toInt64
  fromCql (CqlBigInt i) = Right (fromInt64 i)
  fromCql _             = Left "Expected CqlBigInt."
#endif

instance FromJSON Settings where
  parseJSON = withObject "ZAuth.Settings" $ \o ->
    Settings <$>
    o .: "keyIndex" <*>
    (UserTokenTimeout <$> o .: "userTokenTimeout") <*>
    (SessionTokenTimeout <$> o .: "sessionTokenTimeout") <*>
    (AccessTokenTimeout <$> o .: "accessTokenTimeout") <*>
    (ProviderTokenTimeout <$> o .: "providerTokenTimeout")

makeLenses ''Settings
makeLenses ''Env

localSettings :: (Settings -> Settings) -> ZAuth a -> ZAuth a
localSettings f za = ZAuth (local (over settings f) (unZAuth za))

readKeys :: Read k => FilePath -> IO (Maybe (NonEmpty k))
readKeys fp = nonEmpty . map read . filter (not . null) . lines <$> readFile fp

mkEnv :: NonEmpty SecretKey -> NonEmpty PublicKey -> Settings -> IO Env
mkEnv sk pk sets = do
    zc <- ZC.mkEnv (NonEmpty.head sk) (NonEmpty.tail sk)
    let zv = ZV.mkEnv (NonEmpty.head pk) (NonEmpty.tail pk)
    return $! Env zc zv sets

mkUserToken :: MonadZAuth m => UserId -> Word32 -> UTCTime -> m UserToken
mkUserToken u r t = liftZAuth $ do
    z <- ask
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        ZC.newToken (utcTimeToPOSIXSeconds t) U Nothing (mkUser (toUUID u) r)

newUserToken :: MonadZAuth m => UserId -> m UserToken
newUserToken u = liftZAuth $ do
    z <- ask
    r <- liftIO randomValue
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        let UserTokenTimeout ttl = z^.settings.userTokenTimeout
        in ZC.userToken ttl (toUUID u) r

newSessionToken :: MonadZAuth m => UserId -> m UserToken
newSessionToken u = liftZAuth $ do
    z <- ask
    r <- liftIO randomValue
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        let SessionTokenTimeout ttl = z^.settings.sessionTokenTimeout
        in ZC.sessionToken ttl (toUUID u) r

newAccessToken :: MonadZAuth m => UserToken -> m AccessToken
newAccessToken xt = liftZAuth $ do
    z <- ask
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        let AccessTokenTimeout ttl = z^.settings.accessTokenTimeout
        in ZC.accessToken1 ttl (xt^.body.user)

renewAccessToken :: MonadZAuth m => AccessToken -> m AccessToken
renewAccessToken old = liftZAuth $ do
    z <- ask
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        let AccessTokenTimeout ttl = z^.settings.accessTokenTimeout
        in ZC.renewToken ttl old

newBotToken :: MonadZAuth m => ProviderId -> BotId -> ConvId -> m BotToken
newBotToken pid bid cid = liftZAuth $ do
    z <- ask
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        ZC.botToken (toUUID pid) (toUUID (botUserId bid)) (toUUID cid)

newProviderToken :: MonadZAuth m => ProviderId -> m ProviderToken
newProviderToken pid = liftZAuth $ do
    z <- ask
    liftIO $ ZC.runCreate (z^.private) (z^.settings.keyIndex) $
        let ProviderTokenTimeout ttl = z^.settings.providerTokenTimeout
        in ZC.providerToken ttl (toUUID pid)

validateToken :: (MonadZAuth m, ToByteString a)
    => Token a
    -> m (Either ZV.Failure ())
validateToken t = liftZAuth $ do
    z <- ask
    void <$> ZV.runValidate (z^.public) (ZV.check t)

accessTokenOf :: AccessToken -> UserId
accessTokenOf t = Id (t^.body.userId)

userTokenOf :: UserToken -> UserId
userTokenOf t = Id (t^.body.user)

userTokenRand :: UserToken -> Word32
userTokenRand t = t^.body.rand

tokenKeyIndex :: Token a -> Int
tokenKeyIndex t = t^.header.key

tokenExpires :: Token a -> POSIXTime
tokenExpires t = fromIntegral (t^.header.time)

tokenExpiresUTC :: Token a -> UTCTime
tokenExpiresUTC = posixSecondsToUTCTime . tokenExpires

randomValue :: IO Word32
randomValue = BS.foldl' f 0 <$> randBytes 4
  where
    f r w = shiftL r 8 .|. fromIntegral w