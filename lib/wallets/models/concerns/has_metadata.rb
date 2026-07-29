# frozen_string_literal: true

module Wallets
  # Shared metadata behavior for ledger records: metadata always reads as a
  # hash with indifferent access, accepts anything hash-like on assignment,
  # and in-place mutations survive `save`.
  #
  # MySQL cannot give JSON columns a default, so a NULL column is treated the
  # same as an empty hash everywhere.
  module HasMetadata
    extend ActiveSupport::Concern

    included do
      before_save :sync_metadata_cache
    end

    # read_attribute/write_attribute, NOT `super`: this concern is included on
    # the abstract *Base classes, while ActiveRecord generates the plain
    # attribute readers/writers lazily on each CONCRETE descendant — below
    # this module in the ancestor chain — so a `super` here can find no
    # generated method to call.
    def metadata
      @indifferent_metadata ||= ActiveSupport::HashWithIndifferentAccess.new(read_attribute(:metadata) || {})
    end

    def metadata=(hash)
      @indifferent_metadata = nil
      write_attribute(:metadata, hash.respond_to?(:to_h) ? hash.to_h : {})
    end

    def reload(*)
      @indifferent_metadata = nil
      super
    end

    private

    def sync_metadata_cache
      if @indifferent_metadata
        write_attribute(:metadata, @indifferent_metadata.to_h)
      elsif read_attribute(:metadata).nil?
        write_attribute(:metadata, {})
      end
    end
  end
end
