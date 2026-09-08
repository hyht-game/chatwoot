require 'rails_helper'

RSpec.describe 'Contact page replies', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:client) { instance_double(Integrations::Translation::OpenaiCompatibleClient) }
  let!(:provider) do
    create(:integrations_hook, account: account, app_id: 'translation', settings: {
             'name' => 'Test', 'provider' => 'openai_compatible', 'api_base' => 'https://example.com/v1',
             'model' => 'test', 'agent_language' => 'zh-CN'
           })
  end
  let(:payload) do
    { contact_id: contact.id, inbox_id: inbox.id, source_id: contact_inbox.source_id,
      message: { content: '您好', private: false } }
  end

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    allow(Integrations::Translation::ProviderClient).to receive(:for).and_return(client)
  end

  it 'creates a conversation with only the English translation and does not fix the language to English' do
    expect(client).to receive(:translate).with(content: '您好', target_language: 'en').and_return('Hello')
    expect do
      post "/api/v1/accounts/#{account.id}/conversations", params: payload, headers: agent.create_new_auth_token, as: :json
    end.to change(Conversation, :count).by(1)
    expect(response).to have_http_status(:success)
    conversation = contact_inbox.conversations.last
    expect(conversation.language).to be_blank
    expect(conversation.messages.outgoing.pluck(:content)).to eq(['Hello'])
    expect(conversation.messages.outgoing.last.content_attributes.to_json).not_to include('您好')
  end

  %w[open resolved snoozed].each do |status|
    it "continues an existing #{status} conversation in the customer language" do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                           status: status, additional_attributes: { conversation_language: 'es' })
      expect(client).to receive(:translate).with(content: '您好', target_language: 'es').and_return('Hola')
      expect do
        post "/api/v1/accounts/#{account.id}/conversations", params: payload, headers: agent.create_new_auth_token, as: :json
      end.not_to change(Conversation, :count)
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(conversation.display_id)
      expect(conversation.reload).to be_open
      expect(conversation.messages.outgoing.last.content).to eq('Hola')
    end
  end

  it 'keeps a resolved conversation closed and saves no message when translation fails' do
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)
    allow(client).to receive(:translate).and_raise(CustomExceptions::TranslationProviderError, 'Translation unavailable')
    expect do
      post "/api/v1/accounts/#{account.id}/conversations", params: payload, headers: agent.create_new_auth_token, as: :json
    end.not_to change(Message, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(conversation.reload).to be_resolved
  end

  it 'sends unchanged when translation is disabled' do
    provider.disable
    expect(client).not_to receive(:translate)
    post "/api/v1/accounts/#{account.id}/conversations", params: payload, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
    expect(contact_inbox.conversations.last.messages.outgoing.last.content).to eq('您好')
  end
end
