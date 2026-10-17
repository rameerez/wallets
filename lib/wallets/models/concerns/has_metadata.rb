# frozen_string_literal: true

module Wallets
  # Shared metadata behavior for ledger records: metadata always reads as a
  # hash with indifferent access, accepts anything hash-like on assignment,
  # and in-place mutations survive `save`.
  #
  # MySQL cannot give JSON columns a default, so a NULL column is treated the
  # same as an empty hash everywhere.
  #
  # Including the concern gives the `metadata` column this behavior. A model
  # with another JSON column of the same kind names it:
  #
  #   has_metadata_column :release_metadata
  module HasMetadata
    extend ActiveSupport::Concern

    included do
      class_attribute :metadata_column_names, default: [].freeze, instance_writer: false, instance_predicate: false

      before_save :sync_metadata_cache

      has_metadata_column :metadata
    end

    class_methods do
      def has_metadata_column(name)
        name = name.to_sym
        cache = :"@indifferent_#{name}"
        self.metadata_column_names = (metadata_column_names + [name]).freeze

        # A module, not methods on the class itself, so the including class
        # can still override an accessor and call `super`.
        #
        # read_attribute/write_attribute, NOT `super`: this concern is included
        # on the abstract *Base classes, while ActiveRecord generates the plain
        # attribute readers/writers lazily on each CONCRETE descendant — below
        # this module in the ancestor chain — so a `super` here can find no
        # generated method to call.
        include(Module.new do
          define_method(name) do
            instance_variable_get(cache) ||
              instance_variable_set(cache, ActiveSupport::HashWithIndifferentAccess.new(read_attribute(name) || {}))
          end

          define_method(:"#{name}=") do |hash|
            instance_variable_set(cache, nil)
            write_attribute(name, hash.respond_to?(:to_h) ? hash.to_h : {})
          end
        end)
      end
    end

    def reload(*)
      metadata_column_names.each { |name| instance_variable_set(:"@indifferent_#{name}", nil) }
      super
    end

    private

    def sync_metadata_cache
      metadata_column_names.each do |name|
        cached = instance_variable_get(:"@indifferent_#{name}")

        if cached
          write_attribute(name, cached.to_h)
        elsif read_attribute(name).nil?
          write_attribute(name, {})
        end
      end
    end
  end
end
