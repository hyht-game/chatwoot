class Integrations::Translation::ProviderClient
  CLIENTS = {
    'openai_compatible' => Integrations::Translation::OpenaiCompatibleClient,
    'deepseek' => Integrations::Translation::OpenaiCompatibleClient
  }.freeze

  def self.for(hook)
    CLIENTS.fetch(hook.settings['provider']).new(hook: hook)
  rescue KeyError
    raise CustomExceptions::TranslationProviderError, I18n.t('errors.translation.unsupported_provider')
  end
end
