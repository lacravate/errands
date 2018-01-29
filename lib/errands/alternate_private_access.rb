module Errands

  module AlternatePrivateAccess

    def self.included(singleton)
      class << singleton
        attr_accessor :errands_store
      end
    end

    def self.extended(klass)
      class << klass
        attr_accessor :errands_store
      end
    end

    def set_store(store)
      singleton_class.errands_store = store
    end

    private

    def our_store!(h = nil)
      (Thread.main[singleton_class.errands_store] = h || {}).tap do |store|
        if t = store[:threads]
          t.singleton_class.include AlternatePrivateAccess
          t.singleton_class.errands_store = singleton_class.errands_store
        end

        if r = Thread.main[singleton_class.errands_store][:receptors]
          r.singleton_class.include AlternatePrivateAccess
          r.singleton_class.errands_store = singleton_class.errands_store

          def r.default(key)
            self[key] = Errands::Receptors::Receptor.new(key).tap do |v|
              v.singleton_class.include Errands::AlternatePrivateAccess
              v.singleton_class.errands_store = singleton_class.errands_store
            end
          end
        end

      end
    end

    def our
      singleton_class.errands_store && Thread.main[singleton_class.errands_store]
    end

  end

end
