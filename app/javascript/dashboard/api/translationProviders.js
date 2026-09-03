/* global axios */
import ApiClient from './ApiClient';

class TranslationProvidersAPI extends ApiClient {
  constructor() {
    super('integrations/translation_providers', { accountScoped: true });
  }

  create(data) {
    return axios.post(this.url, { translation_provider: data });
  }

  update(id, data) {
    return axios.patch(`${this.url}/${id}`, { translation_provider: data });
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  test(id) {
    return axios.post(`${this.url}/${id}/test`);
  }
}

export default new TranslationProvidersAPI();
