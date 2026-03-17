class User < ApplicationRecord
  has_wallets default_asset: :coins
end
