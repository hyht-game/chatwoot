class AddUniqueEnabledTranslationProviderIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :integrations_hooks, :account_id,
              unique: true,
              where: "app_id = 'translation' AND status = 1",
              name: 'index_integrations_hooks_on_enabled_translation_provider',
              algorithm: :concurrently
  end
end
