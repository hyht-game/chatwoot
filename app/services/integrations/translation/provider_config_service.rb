class Integrations::Translation::ProviderConfigService
  DEFAULT_PROVIDER = 'openai_compatible'.freeze
  DEFAULT_AGENT_LANGUAGE = 'zh-CN'.freeze
  SETTINGS_KEYS = %i[name provider api_base model agent_language].freeze

  pattr_initialize [:account!]

  def create!(attributes)
    api_key = attributes.delete(:api_key).presence
    raise CustomExceptions::TranslationProviderError, I18n.t('errors.translation.api_key_required') if api_key.blank?

    hook = account.hooks.new(app_id: 'translation', access_token: api_key)
    assign_attributes(hook, attributes, new_record: true)
    persist!(hook)
  end

  def update!(hook, attributes)
    hook.access_token = attributes.delete(:api_key) if attributes[:api_key].present?
    assign_attributes(hook, attributes, new_record: false)
    persist!(hook)
  end

  private

  def assign_attributes(hook, attributes, new_record:)
    settings = hook.settings.to_h.merge(attributes.slice(*SETTINGS_KEYS).stringify_keys)
    settings['provider'] ||= DEFAULT_PROVIDER
    settings['agent_language'] ||= DEFAULT_AGENT_LANGUAGE

    hook.settings = settings
    enabled = attributes.key?(:enabled) ? ActiveModel::Type::Boolean.new.cast(attributes[:enabled]) : !new_record && hook.enabled?
    hook.status = enabled ? :enabled : :disabled
  end

  def persist!(hook)
    raise ActiveRecord::RecordInvalid, hook unless hook.valid?

    Integrations::Translation::ProviderClient.for(hook).test! if hook.enabled?

    account.with_lock do
      disable_other_providers(hook) if hook.enabled?
      hook.save!
    end

    hook
  end

  def disable_other_providers(hook)
    scope = account.hooks.where(app_id: 'translation', status: :enabled)
    scope = scope.where.not(id: hook.id) if hook.persisted?
    scope.find_each(&:disable)
  end
end
