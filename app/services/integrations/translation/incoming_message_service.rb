class Integrations::Translation::IncomingMessageService
  pattr_initialize [:hook!, :message!]

  def perform
    return unless valid_message?

    source_language = resolved_source_language
    persist_conversation_language(source_language)
    return if same_language?(source_language, target_language)

    message.update!(translations: translated_messages)
  end

  private

  def valid_message?
    message.incoming? && !message.private? && message.content.present?
  end

  def resolved_source_language
    message.conversation.language.presence || client.detect_language(content: message.content.first(1500))
  end

  def translated_messages
    translated_content = client.translate(content: message.content, target_language: target_language)
    message.translations.to_h.merge(translation_key => translated_content)
  end

  def persist_conversation_language(language)
    return if message.conversation.language.present?

    attributes = message.conversation.additional_attributes.merge('conversation_language' => language)
    message.conversation.update!(additional_attributes: attributes)
  end

  def target_language
    hook.settings['agent_language']
  end

  def translation_key
    target_language.tr('-', '_')
  end

  def same_language?(first, second)
    first.to_s.split(/[-_]/).first.casecmp?(second.to_s.split(/[-_]/).first)
  end

  def client
    @client ||= Integrations::Translation::ProviderClient.for(hook)
  end
end
