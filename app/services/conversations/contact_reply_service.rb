class Conversations::ContactReplyService
  pattr_initialize [:contact_inbox!, :user!, :params!]

  def perform
    contact_inbox.with_lock do
      conversation = contact_inbox.conversations.order(:id).last if contact_inbox.inbox.web_widget? && params[:message].present?
      yield conversation if conversation
      conversation ||= ConversationBuilder.new(params: params, contact_inbox: contact_inbox).perform
      send_message(conversation) if params[:message].present?
      conversation
    end
  end

  private

  def send_message(conversation)
    message_params = Messages::OutgoingTranslationService.new(conversation: conversation, user: user, params: params[:message]).perform
    message = Messages::MessageBuilder.new(user, conversation, message_params).perform
    return unless conversation.inbox.web_widget? && message.outgoing? && !message.private? && !conversation.open?

    reopen_conversation(conversation)
  end

  def reopen_conversation(conversation)
    conversation.assign_attributes(status: :open, snoozed_until: nil)
    if user.is_a?(User)
      conversation.ai_assignee = nil
      conversation.assignee = user if user.agent?
    end
    conversation.save!
  end
end
