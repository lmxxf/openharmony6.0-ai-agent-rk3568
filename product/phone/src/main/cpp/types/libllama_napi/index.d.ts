/**
 * llama.cpp NAPI interface for OpenHarmony
 */

/**
 * Load a GGUF model file
 * @param modelPath - Absolute path to the .gguf model file
 * @param nThreads - Number of CPU threads to use (default: 4)
 * @returns true if model loaded successfully
 */
export function loadModel(modelPath: string, nThreads?: number): boolean;

/**
 * Unload the current model and free resources
 */
export function unloadModel(): void;

/**
 * Check if a model is currently loaded
 * @returns true if model is loaded and ready
 */
export function isModelLoaded(): boolean;

/**
 * Generate text from a prompt (synchronous)
 * @param prompt - The input prompt
 * @param maxTokens - Maximum tokens to generate (default: 256)
 * @returns Generated text
 */
export function generate(prompt: string, maxTokens?: number): string;

/**
 * Stop ongoing generation
 */
export function stopGeneration(): void;
