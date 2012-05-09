module Acts
  module Importable

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods

      def acts_as_importable(options = {})
        # Store the import target class with the legacy class
        write_inheritable_attribute :importable_to, options[:to]

        # Don't extend or include twice. This will allow acts_as_importable to be called multiple times.
        # eg. once in a parent class and once again in the child class, where it can override some options.
        extend  Acts::Importable::SingletonMethods unless self.methods.include?('import') && self.methods.include?('import_all')
        include Acts::Importable::InstanceMethods unless self.included_modules.include?(Acts::Importable::InstanceMethods)
      end

    end # ClassMethods

    module SingletonMethods
      def import(id)
        find(id).import
      end

      def import_all
        all.each do |legacy_model|
          legacy_model.import
        end
      end

      # This requires a numeric primary key for the legacy tables
      def import_all_in_batches
        if GC.respond_to?(:copy_on_write_friendly=)
          GC.copy_on_write_friendly = true
        end

        jobs_per_process = 2000
        process_count = 4

        find_in_batches(:batch_size => jobs_per_process * process_count) do |group|
          batches = group.in_groups(process_count)

          threads = batches.map do |batch|
            #Process.fork do
            Thread.fork do
              #ActiveRecord::Base.establish_connection

              # Do the actual work
              batch.compact.each {|legacy_model| legacy_model.import unless legacy_model.nil? }
            end
          end

          #Process.waitall
          threads.each &:join
        end
      end

      def lookup(id)
        lookup_class = read_inheritable_attribute(:importable_to) || "#{self.to_s.split('::').last}"
        lookups[id] ||= Kernel.const_get(lookup_class).first(:conditions => {:legacy_id => id, :legacy_class => self.to_s}).try(:id__)
      end

      def flush_lookups!
        @lookups = {}
      end

      private

      def lookups
        @lookups ||= {}
      end

    end # SingletonMethods

    module InstanceMethods

      def import
        to_model.tap do |new_model|
          if new_model
            new_model.legacy_id     = self.id         if new_model.respond_to?(:"legacy_id=")
            new_model.legacy_class  = self.class.to_s if new_model.respond_to?(:"legacy_class=")

            if !new_model.save
              p new_model.errors
              # TODO log an error that the model failed to save
              # TODO remove the raise once we're out of the development cycle
              raise
            else
              after_import(new_model) if self.respond_to? :after_import
            end
          end
        end
      end
    end # InstanceMethods

  end
end

require 'core_extensions'
ActiveRecord::Base.class_eval { include Acts::Importable }

