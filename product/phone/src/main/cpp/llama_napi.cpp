/**
 * llama.cpp NAPI wrapper for OpenHarmony
 *
 * Provides: loadModel(), generate(), unloadModel()
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <string>
#include <vector>
#include <mutex>
#include <thread>
#include <atomic>
#include <cerrno>
#include <cstdio>

#include "llama.h"

#define LOG_TAG "LlamaNAPI"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// Global state
static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static llama_sampler* g_sampler = nullptr;
static std::mutex g_mutex;
static std::atomic<bool> g_generating{false};

// Helper: Get string from napi_value
static std::string GetStringArg(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string str(len, '\0');
    napi_get_value_string_utf8(env, value, &str[0], len + 1, &len);
    return str;
}

// Helper: Create napi string
static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

// Helper: Create napi boolean
static napi_value CreateBool(napi_env env, bool value) {
    napi_value result;
    napi_get_boolean(env, value, &result);
    return result;
}

/**
 * loadModel(modelPath: string, nThreads?: number): boolean
 */
static napi_value LoadModel(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_mutex);

    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        LOGE("loadModel requires modelPath argument");
        return CreateBool(env, false);
    }

    std::string modelPath = GetStringArg(env, args[0]);

    int nThreads = 4;
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &nThreads);
    }

    LOGI("Loading model: %{public}s with %{public}d threads", modelPath.c_str(), nThreads);

    // Unload existing model
    if (g_sampler) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = nullptr;
    }
    if (g_model) {
        llama_model_free(g_model);
        g_model = nullptr;
    }

    // Check if file exists and is readable
    FILE* f = fopen(modelPath.c_str(), "rb");
    if (!f) {
        LOGE("Cannot open file: %{public}s, errno=%{public}d", modelPath.c_str(), errno);
        return CreateBool(env, false);
    }
    fseek(f, 0, SEEK_END);
    long fileSize = ftell(f);
    fclose(f);
    LOGI("File size: %{public}ld bytes", fileSize);

    // Load model
    llama_model_params model_params = llama_model_default_params();
    LOGI("Calling llama_model_load_from_file...");
    g_model = llama_model_load_from_file(modelPath.c_str(), model_params);

    if (!g_model) {
        LOGE("llama_model_load_from_file returned NULL for: %{public}s", modelPath.c_str());
        return CreateBool(env, false);
    }

    // Create context
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 2048;
    ctx_params.n_threads = nThreads;
    ctx_params.n_threads_batch = nThreads;

    g_ctx = llama_init_from_model(g_model, ctx_params);

    if (!g_ctx) {
        LOGE("Failed to create context");
        llama_model_free(g_model);
        g_model = nullptr;
        return CreateBool(env, false);
    }

    // Create sampler chain
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    g_sampler = llama_sampler_chain_init(sparams);

    // Add samplers: temperature -> top_p -> greedy
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    LOGI("Model loaded successfully");
    return CreateBool(env, true);
}

/**
 * unloadModel(): void
 */
static napi_value UnloadModel(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_sampler) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = nullptr;
    }
    if (g_model) {
        llama_model_free(g_model);
        g_model = nullptr;
    }

    LOGI("Model unloaded");

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * isModelLoaded(): boolean
 */
static napi_value IsModelLoaded(napi_env env, napi_callback_info info) {
    return CreateBool(env, g_model != nullptr && g_ctx != nullptr);
}

// Async generate context
struct GenerateAsyncContext {
    napi_async_work work;
    napi_deferred deferred;
    std::string prompt;
    int maxTokens;
    std::string result;
    bool success;
};

// Worker thread function - does the actual generation
static void GenerateExecute(napi_env env, void* data) {
    GenerateAsyncContext* ctx = static_cast<GenerateAsyncContext*>(data);

    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_model || !g_ctx || !g_sampler) {
        ctx->result = "[Error: Model not loaded]";
        ctx->success = false;
        return;
    }

    LOGI("Generating with prompt length: %{public}zu, max tokens: %{public}d",
         ctx->prompt.length(), ctx->maxTokens);

    // Tokenize prompt
    const llama_vocab* vocab = llama_model_get_vocab(g_model);
    std::vector<llama_token> tokens(ctx->prompt.length() + 32);
    int n_tokens = llama_tokenize(vocab, ctx->prompt.c_str(), ctx->prompt.length(),
                                   tokens.data(), tokens.size(), true, true);

    if (n_tokens < 0) {
        tokens.resize(-n_tokens);
        n_tokens = llama_tokenize(vocab, ctx->prompt.c_str(), ctx->prompt.length(),
                                   tokens.data(), tokens.size(), true, true);
    }
    tokens.resize(n_tokens);

    LOGI("Tokenized to %{public}d tokens", n_tokens);

    // Clear KV cache
    llama_memory_t mem = llama_get_memory(g_ctx);
    if (mem) {
        llama_memory_clear(mem, true);
    }

    // Reset sampler state for new generation
    llama_sampler_reset(g_sampler);

    // Create batch
    llama_batch batch = llama_batch_init(tokens.size(), 0, 1);

    for (int i = 0; i < n_tokens; i++) {
        batch.token[i] = tokens[i];
        batch.pos[i] = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = (i == n_tokens - 1);
    }
    batch.n_tokens = n_tokens;

    // Decode prompt
    if (llama_decode(g_ctx, batch) != 0) {
        llama_batch_free(batch);
        ctx->result = "[Error: decode failed]";
        ctx->success = false;
        return;
    }

    // Generate tokens
    g_generating = true;

    for (int i = 0; i < ctx->maxTokens && g_generating; i++) {
        llama_token new_token = llama_sampler_sample(g_sampler, g_ctx, -1);

        // Check for EOS
        if (llama_vocab_is_eog(vocab, new_token)) {
            break;
        }

        // Convert token to text
        char buf[256];
        int len = llama_token_to_piece(vocab, new_token, buf, sizeof(buf), 0, true);
        if (len > 0) {
            ctx->result.append(buf, len);
        }

        // Prepare next batch
        batch.n_tokens = 1;
        batch.token[0] = new_token;
        batch.pos[0] = n_tokens + i;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = true;

        if (llama_decode(g_ctx, batch) != 0) {
            LOGE("Failed to decode token %{public}d", i);
            break;
        }
    }

    g_generating = false;
    llama_batch_free(batch);

    LOGI("Generated %{public}zu chars", ctx->result.length());
    ctx->success = true;
}

// Complete callback - runs on main thread, resolves the promise
static void GenerateComplete(napi_env env, napi_status status, void* data) {
    GenerateAsyncContext* ctx = static_cast<GenerateAsyncContext*>(data);

    napi_value result;
    napi_create_string_utf8(env, ctx->result.c_str(), ctx->result.length(), &result);

    if (ctx->success) {
        napi_resolve_deferred(env, ctx->deferred, result);
    } else {
        napi_reject_deferred(env, ctx->deferred, result);
    }

    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

/**
 * generate(prompt: string, maxTokens?: number): Promise<string>
 *
 * Asynchronous generation - returns a Promise
 */
static napi_value Generate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_value promise;
        napi_deferred deferred;
        napi_create_promise(env, &deferred, &promise);
        napi_value error;
        napi_create_string_utf8(env, "[Error: prompt required]", NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // Create async context
    GenerateAsyncContext* ctx = new GenerateAsyncContext();
    ctx->prompt = GetStringArg(env, args[0]);
    ctx->maxTokens = 256;
    ctx->success = false;

    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &ctx->maxTokens);
    }

    // Create promise
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);

    // Create async work
    napi_value resourceName;
    napi_create_string_utf8(env, "llama_generate", NAPI_AUTO_LENGTH, &resourceName);

    napi_create_async_work(env, nullptr, resourceName,
                           GenerateExecute, GenerateComplete,
                           ctx, &ctx->work);

    napi_queue_async_work(env, ctx->work);

    LOGI("Generate async work queued");
    return promise;
}

/**
 * stopGeneration(): void
 */
static napi_value StopGeneration(napi_env env, napi_callback_info info) {
    g_generating = false;

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Module initialization
static napi_value Init(napi_env env, napi_value exports) {
    LOGI("LlamaNAPI: Native module Init calling...");
    // Initialize llama backend
    llama_backend_init();

    napi_property_descriptor desc[] = {
        {"loadModel", nullptr, LoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unloadModel", nullptr, UnloadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isModelLoaded", nullptr, IsModelLoaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generate", nullptr, Generate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopGeneration", nullptr, StopGeneration, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    LOGI("llama NAPI module initialized");
    return exports;
}

EXTERN_C_START
static napi_module llamaModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "libllama_napi.so",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterLlamaModule(void) {
    napi_module_register(&llamaModule);
}
EXTERN_C_END
