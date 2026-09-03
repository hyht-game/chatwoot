class Api::V1::Accounts::Integrations::TranslationProvidersController < Api::V1::Accounts::Integrations::BaseController
  before_action :fetch_provider, only: [:update, :destroy, :test]
  before_action :check_authorization

  rescue_from CustomExceptions::TranslationProviderError, with: :render_translation_error

  def index
    render json: { payload: providers.map { |provider| provider_payload(provider) } }
  end

  def create
    provider = config_service.create!(provider_params.to_h.symbolize_keys)
    render json: provider_payload(provider)
  end

  def update
    provider = config_service.update!(@provider, provider_params.to_h.symbolize_keys)
    render json: provider_payload(provider)
  end

  def destroy
    @provider.destroy!
    head :ok
  end

  def test
    Integrations::Translation::ProviderClient.for(@provider).test!
    render json: { success: true }
  end

  private

  def providers
    Current.account.hooks.where(app_id: 'translation').order(:id)
  end

  def fetch_provider
    @provider = providers.find(params[:id])
  end

  def config_service
    @config_service ||= Integrations::Translation::ProviderConfigService.new(account: Current.account)
  end

  def provider_params
    params.require(:translation_provider).permit(:name, :provider, :api_base, :api_key, :model, :agent_language, :enabled)
  end

  def provider_payload(provider)
    provider.settings.slice('name', 'provider', 'api_base', 'model', 'agent_language').merge(
      id: provider.id,
      enabled: provider.enabled?,
      has_api_key: provider.access_token.present?
    )
  end

  def render_translation_error(error)
    render_could_not_create_error(error.message)
  end
end
