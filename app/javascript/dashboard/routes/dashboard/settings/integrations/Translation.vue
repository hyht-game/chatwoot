<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';

import TranslationProvidersAPI from 'dashboard/api/translationProviders';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Label from 'dashboard/components-next/label/Label.vue';
import {
  BaseTable,
  BaseTableCell,
  BaseTableRow,
} from 'dashboard/components-next/table';

const EMPTY_FORM = {
  name: '',
  provider: 'openai_compatible',
  api_base: '',
  api_key: '',
  model: '',
  agent_language: 'zh-CN',
  enabled: false,
};

const { t } = useI18n();
const providers = ref([]);
const isLoading = ref(false);
const isSaving = ref(false);
const testingProviderId = ref(null);
const showForm = ref(false);
const showDeleteConfirmation = ref(false);
const editingProviderId = ref(null);
const providerToDelete = ref(null);
const form = reactive({ ...EMPTY_FORM });

const headers = computed(() => [
  t('TRANSLATION_PROVIDERS.TABLE.NAME'),
  t('TRANSLATION_PROVIDERS.TABLE.PROVIDER'),
  t('TRANSLATION_PROVIDERS.TABLE.API_BASE'),
  t('TRANSLATION_PROVIDERS.TABLE.MODEL'),
  t('TRANSLATION_PROVIDERS.TABLE.STATUS'),
  t('TRANSLATION_PROVIDERS.TABLE.ACTIONS'),
]);

const formTitle = computed(() =>
  editingProviderId.value
    ? t('TRANSLATION_PROVIDERS.FORM.EDIT_TITLE')
    : t('TRANSLATION_PROVIDERS.FORM.ADD_TITLE')
);

const providerLabel = provider => {
  if (provider === 'deepseek') {
    return t('TRANSLATION_PROVIDERS.PROVIDERS.DEEPSEEK');
  }
  return t('TRANSLATION_PROVIDERS.PROVIDERS.OPENAI_COMPATIBLE');
};

const fetchProviders = async () => {
  isLoading.value = true;
  try {
    const { data } = await TranslationProvidersAPI.get();
    providers.value = data.payload;
  } catch (error) {
    useAlert(
      error?.response?.data?.error || t('TRANSLATION_PROVIDERS.ERROR.LOAD')
    );
  } finally {
    isLoading.value = false;
  }
};

const resetForm = () => {
  Object.assign(form, EMPTY_FORM);
  editingProviderId.value = null;
};

const openCreateForm = () => {
  resetForm();
  showForm.value = true;
};

const openEditForm = provider => {
  editingProviderId.value = provider.id;
  Object.assign(form, {
    name: provider.name,
    provider: provider.provider,
    api_base: provider.api_base,
    api_key: '',
    model: provider.model,
    agent_language: provider.agent_language,
    enabled: provider.enabled,
  });
  showForm.value = true;
};

const closeForm = () => {
  showForm.value = false;
  resetForm();
};

const errorMessage = error =>
  error?.response?.data?.error ||
  error?.response?.data?.message ||
  t('TRANSLATION_PROVIDERS.ERROR.SAVE');

const saveProvider = async () => {
  isSaving.value = true;
  try {
    if (editingProviderId.value) {
      await TranslationProvidersAPI.update(editingProviderId.value, form);
    } else {
      await TranslationProvidersAPI.create(form);
    }
    useAlert(t('TRANSLATION_PROVIDERS.SUCCESS.SAVED'));
    closeForm();
    await fetchProviders();
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    isSaving.value = false;
  }
};

const updateStatus = async provider => {
  try {
    await TranslationProvidersAPI.update(provider.id, {
      enabled: provider.enabled,
    });
    useAlert(
      provider.enabled
        ? t('TRANSLATION_PROVIDERS.SUCCESS.ENABLED')
        : t('TRANSLATION_PROVIDERS.SUCCESS.DISABLED')
    );
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    await fetchProviders();
  }
};

const testProvider = async provider => {
  testingProviderId.value = provider.id;
  try {
    await TranslationProvidersAPI.test(provider.id);
    useAlert(t('TRANSLATION_PROVIDERS.SUCCESS.TESTED'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error || t('TRANSLATION_PROVIDERS.ERROR.TEST')
    );
  } finally {
    testingProviderId.value = null;
  }
};

const openDeleteConfirmation = provider => {
  providerToDelete.value = provider;
  showDeleteConfirmation.value = true;
};

const deleteProvider = async () => {
  try {
    await TranslationProvidersAPI.delete(providerToDelete.value.id);
    useAlert(t('TRANSLATION_PROVIDERS.SUCCESS.DELETED'));
    showDeleteConfirmation.value = false;
    await fetchProviders();
  } catch (error) {
    useAlert(
      error?.response?.data?.error || t('TRANSLATION_PROVIDERS.ERROR.DELETE')
    );
  }
};

onMounted(fetchProviders);
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :loading-message="$t('TRANSLATION_PROVIDERS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('TRANSLATION_PROVIDERS.TITLE')"
        :description="$t('TRANSLATION_PROVIDERS.DESCRIPTION')"
        :back-button-label="$t('INTEGRATION_SETTINGS.HEADER')"
        feature-name="integrations"
      >
        <template #actions>
          <Button
            :label="$t('TRANSLATION_PROVIDERS.ADD')"
            icon="i-lucide-plus"
            size="sm"
            @click="openCreateForm"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <div
        class="outline outline-1 outline-n-container bg-n-card rounded-xl px-5"
      >
        <BaseTable
          :headers="headers"
          :items="providers"
          :no-data-message="$t('TRANSLATION_PROVIDERS.EMPTY')"
        >
          <template #row="{ items }">
            <BaseTableRow
              v-for="provider in items"
              :key="provider.id"
              :item="provider"
            >
              <BaseTableCell>{{ provider.name }}</BaseTableCell>
              <BaseTableCell>
                {{ providerLabel(provider.provider) }}
              </BaseTableCell>
              <BaseTableCell>
                <span class="break-all">{{ provider.api_base }}</span>
              </BaseTableCell>
              <BaseTableCell>{{ provider.model }}</BaseTableCell>
              <BaseTableCell>
                <div class="flex items-center gap-2">
                  <Switch
                    v-model="provider.enabled"
                    @change="updateStatus(provider)"
                  />
                  <Label
                    :label="
                      provider.enabled
                        ? $t('INTEGRATION_APPS.STATUS.ENABLED')
                        : $t('INTEGRATION_APPS.STATUS.DISABLED')
                    "
                    :color="provider.enabled ? 'teal' : 'slate'"
                    compact
                  />
                </div>
              </BaseTableCell>
              <BaseTableCell align="end">
                <div class="flex justify-end gap-2">
                  <Button
                    :label="$t('TRANSLATION_PROVIDERS.TEST')"
                    :is-loading="testingProviderId === provider.id"
                    slate
                    faded
                    size="sm"
                    @click="testProvider(provider)"
                  />
                  <Button
                    icon="i-lucide-pencil"
                    slate
                    ghost
                    size="sm"
                    @click="openEditForm(provider)"
                  />
                  <Button
                    icon="i-woot-bin"
                    ruby
                    ghost
                    size="sm"
                    @click="openDeleteConfirmation(provider)"
                  />
                </div>
              </BaseTableCell>
            </BaseTableRow>
          </template>
        </BaseTable>
      </div>
    </template>

    <woot-modal v-model:show="showForm" :on-close="closeForm">
      <div class="flex flex-col gap-5 p-6">
        <div>
          <h2 class="text-heading-1 text-n-slate-12">{{ formTitle }}</h2>
          <p class="mt-1 mb-0 text-body-main text-n-slate-11">
            {{ $t('TRANSLATION_PROVIDERS.FORM.DESCRIPTION') }}
          </p>
        </div>

        <form class="grid gap-4" @submit.prevent="saveProvider">
          <Input
            v-model="form.name"
            :label="$t('TRANSLATION_PROVIDERS.FORM.NAME')"
            required
          />

          <label
            class="flex flex-col gap-1 mb-0 text-heading-3 text-n-slate-12"
          >
            {{ $t('TRANSLATION_PROVIDERS.FORM.PROVIDER') }}
            <select
              v-model="form.provider"
              class="h-10 px-3 mb-0 text-sm border-0 rounded-lg outline outline-1 outline-n-weak bg-n-alpha-black2 text-n-slate-12"
            >
              <option value="openai_compatible">
                {{ $t('TRANSLATION_PROVIDERS.PROVIDERS.OPENAI_COMPATIBLE') }}
              </option>
              <option value="deepseek">
                {{ $t('TRANSLATION_PROVIDERS.PROVIDERS.DEEPSEEK') }}
              </option>
            </select>
          </label>

          <Input
            v-model="form.api_base"
            :label="$t('TRANSLATION_PROVIDERS.FORM.API_BASE')"
            :placeholder="$t('TRANSLATION_PROVIDERS.FORM.API_BASE_PLACEHOLDER')"
            required
          />
          <Input
            v-model="form.api_key"
            type="password"
            :label="$t('TRANSLATION_PROVIDERS.FORM.API_KEY')"
            :message="
              editingProviderId
                ? $t('TRANSLATION_PROVIDERS.FORM.API_KEY_EDIT_HELP')
                : ''
            "
            :required="!editingProviderId"
          />
          <Input
            v-model="form.model"
            :label="$t('TRANSLATION_PROVIDERS.FORM.MODEL')"
            required
          />
          <Input
            v-model="form.agent_language"
            :label="$t('TRANSLATION_PROVIDERS.FORM.AGENT_LANGUAGE')"
            :message="$t('TRANSLATION_PROVIDERS.FORM.AGENT_LANGUAGE_HELP')"
            required
          />

          <div class="flex items-center justify-between gap-4 py-2">
            <div>
              <p class="mb-0 text-heading-3 text-n-slate-12">
                {{ $t('TRANSLATION_PROVIDERS.FORM.ENABLED') }}
              </p>
              <p class="mt-1 mb-0 text-body-small text-n-slate-11">
                {{ $t('TRANSLATION_PROVIDERS.FORM.ENABLED_HELP') }}
              </p>
            </div>
            <Switch v-model="form.enabled" />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              :label="$t('TRANSLATION_PROVIDERS.FORM.CANCEL')"
              slate
              faded
              @click="closeForm"
            />
            <Button
              type="submit"
              :label="$t('TRANSLATION_PROVIDERS.FORM.SAVE')"
              :is-loading="isSaving"
            />
          </div>
        </form>
      </div>
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteConfirmation"
      :on-confirm="deleteProvider"
      :title="$t('TRANSLATION_PROVIDERS.DELETE.TITLE')"
      :message="$t('TRANSLATION_PROVIDERS.DELETE.MESSAGE')"
      :confirm-text="$t('TRANSLATION_PROVIDERS.DELETE.CONFIRM')"
      :reject-text="$t('TRANSLATION_PROVIDERS.FORM.CANCEL')"
    />
  </SettingsLayout>
</template>
