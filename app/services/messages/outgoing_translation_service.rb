class Messages::OutgoingTranslationService
  pattr_initialize [:conversation!, :user!, :params!]

  def perform
    return params unless should_translate?

    target_language = resolved_target_language
    return params if same_language?(target_language, provider.settings['agent_language'])

    translated_content = client.translate(content: params[:content], target_language: target_language)
    params.deep_dup.tap { |translated_params| translated_params[:content] = translated_content }
  end

  private

  def should_translate?
    provider.present? && human_text_reply?
  end

  def human_text_reply?
    user.is_a?(User) && message_type == 'outgoing' && public_message? && supported_content?
  end

  def public_message?
    !ActiveModel::Type::Boolean.new.cast(params[:private])
  end

  def supported_content?
    params[:content].present? && params[:template_params].blank? && params[:sender_type] != 'AgentBot' &&
      !conversation.inbox.email? && text_content?
  end

  def message_type
    params[:message_type].presence || 'outgoing'
  end

  def text_content?
    params[:content_type].blank? || params[:content_type].to_s.in?(['text', Message.content_types[:text].to_s])
  end

  def resolved_target_language
    return normalize_language(known_target_language) if known_target_language.present?

    detect_target_language
  end

  def known_target_language
    @known_target_language ||= [conversation.language, conversation.additional_attributes['browser_language']]
                               .map { |language| language.to_s.tr('_', '-') }
                               .find { |language| Integrations::Translation::OpenaiCompatibleClient.valid_language?(language) }
  end

  def detect_target_language
    content = latest_incoming_content
    raise CustomExceptions::TranslationProviderError, I18n.t('errors.translation.target_language_missing') if content.blank?

    detected_language = client.detect_language(content: content.first(1500))
    if detected_language.blank?
      raise CustomExceptions::TranslationProviderError, I18n.t('errors.translation.target_language_missing')
    end
    conversation.update!(additional_attributes: conversation.additional_attributes.merge('conversation_language' => detected_language))
    detected_language
  end

  def latest_incoming_content
    conversation.messages.incoming.where(private: false).where.not(content: [nil, '']).last&.content
  end

  def normalize_language(language)
    normalized = language.to_s.tr('_', '-')
    return normalized if normalized.match?(Integrations::Translation::OpenaiCompatibleClient::LANGUAGE_CODE_PATTERN)

    raise CustomExceptions::TranslationProviderError, I18n.t('errors.translation.target_language_invalid')
  end

  def same_language?(first, second)
    first.to_s.split(/[-_]/).first.casecmp?(second.to_s.split(/[-_]/).first)
  end

  def provider
    @provider ||= conversation.account.hooks.find_by(app_id: 'translation', status: :enabled)
  end

  def client
    @client ||= Integrations::Translation::ProviderClient.for(provider)
  end
end
