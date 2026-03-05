/**
 * VectorRagService — 向量 RAG 检索服务
 *
 * 用 SiliconFlow BGE-M3 算 embedding，SQLite 存向量，余弦相似度检索。
 * 降级策略：API 不可用时返回空结果，由调用方降级到关键词匹配。
 */

import relationalStore from '@ohos.data.relationalStore';
import http from '@ohos.net.http';
import LogUtil from '../../../../../../../common/utils/src/main/ets/default/baseUtil/LogUtil';

// ============================================================
// 类型定义
// ============================================================

export interface VectorRagConfig {
  apiKey: string;
  apiUrl: string;
  model: string;
}

interface EmbeddingRequest {
  model: string;
  input: string[];
  encoding_format: string;
}

interface EmbeddingDataItem {
  embedding: number[];
  index: number;
  object: string;
}

interface EmbeddingResponse {
  data: EmbeddingDataItem[];
  model: string;
  object: string;
}

export interface ScoredVectorChunk {
  text: string;
  score: number;
  docId: string;
}

// KbChunk 与 aiAssistant.ets 中定义一致
export interface KbChunkInput {
  docId: string;
  text: string;
  keywords: string[];
}

type VectorRagStatus = 'uninitialized' | 'indexing' | 'ready' | 'fallback';

// ============================================================
// 常量
// ============================================================

const TAG = '[VectorRAG]';
const DB_NAME = 'vector_rag.db';
const TABLE_CHUNKS = 'kb_vector_chunks';
const TABLE_META = 'kb_meta';
const BATCH_SIZE = 5;

const CREATE_CHUNKS_SQL =
  `CREATE TABLE IF NOT EXISTS ${TABLE_CHUNKS} (` +
  'id INTEGER PRIMARY KEY AUTOINCREMENT,' +
  'doc_id TEXT NOT NULL,' +
  'chunk_index INTEGER NOT NULL,' +
  'chunk_text TEXT NOT NULL,' +
  'embedding BLOB NOT NULL)';

const CREATE_META_SQL =
  `CREATE TABLE IF NOT EXISTS ${TABLE_META} (` +
  'key TEXT PRIMARY KEY,' +
  'value TEXT NOT NULL)';

// ============================================================
// VectorRagService
// ============================================================

export class VectorRagService {
  private store: relationalStore.RdbStore | null = null;
  private config: VectorRagConfig | null = null;
  private status: VectorRagStatus = 'uninitialized';

  // --------------------------------------------------------
  // 公开接口
  // --------------------------------------------------------

  getStatus(): VectorRagStatus {
    return this.status;
  }

  isReady(): boolean {
    return this.status === 'ready';
  }

  /**
   * 初始化数据库
   */
  async init(context: Context, config: VectorRagConfig): Promise<void> {
    this.config = config;

    if (!config.apiKey || config.apiKey.length === 0) {
      LogUtil.info(TAG + ' No API key, fallback to keyword RAG');
      this.status = 'fallback';
      return;
    }

    try {
      const storeConfig: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(context, storeConfig);
      await this.store.executeSql(CREATE_CHUNKS_SQL);
      await this.store.executeSql(CREATE_META_SQL);
      LogUtil.info(TAG + ' Database initialized');
    } catch (e) {
      LogUtil.error(TAG + ' DB init failed: ' + JSON.stringify(e));
      this.status = 'fallback';
    }
  }

  /**
   * 构建向量索引（首次或 chunk 数变化时）
   */
  async buildIndex(chunks: KbChunkInput[]): Promise<boolean> {
    if (!this.store || !this.config || this.status === 'fallback') {
      return false;
    }

    // 检查是否已建索引
    const existingCount = await this.getMetaValue('chunk_count');
    if (existingCount === chunks.length.toString()) {
      LogUtil.info(TAG + ' Index up to date (' + existingCount + ' chunks), skip');
      this.status = 'ready';
      return true;
    }

    this.status = 'indexing';
    LogUtil.info(TAG + ' Building index for ' + chunks.length + ' chunks...');

    try {
      // 清空旧数据
      await this.store.executeSql('DELETE FROM ' + TABLE_CHUNKS);

      // 分批计算 embedding
      for (let i = 0; i < chunks.length; i += BATCH_SIZE) {
        const batch = chunks.slice(i, i + BATCH_SIZE);
        const texts = batch.map(c => c.text);
        const embeddings = await this.callEmbeddingApi(texts);

        if (!embeddings || embeddings.length !== texts.length) {
          throw new Error('Embedding API returned wrong count: expected ' +
            texts.length + ', got ' + (embeddings ? embeddings.length : 0));
        }

        // 逐条存入 SQLite
        for (let j = 0; j < batch.length; j++) {
          const chunk = batch[j];
          const embedding = embeddings[j];
          const blob = this.floatArrayToBlob(embedding);

          const row: relationalStore.ValuesBucket = {
            'doc_id': chunk.docId,
            'chunk_index': i + j,
            'chunk_text': chunk.text,
            'embedding': blob
          };
          await this.store.insert(TABLE_CHUNKS, row);
        }

        LogUtil.info(TAG + ' Indexed batch ' + (Math.floor(i / BATCH_SIZE) + 1) +
          '/' + Math.ceil(chunks.length / BATCH_SIZE));
      }

      // 更新元数据
      await this.setMetaValue('chunk_count', chunks.length.toString());

      this.status = 'ready';
      LogUtil.info(TAG + ' Index built successfully: ' + chunks.length + ' chunks');
      return true;
    } catch (e) {
      LogUtil.error(TAG + ' buildIndex failed: ' + JSON.stringify(e));
      this.status = 'fallback';
      return false;
    }
  }

  /**
   * 向量检索
   */
  async retrieveByVector(query: string, topK: number): Promise<string[]> {
    if (!this.store || !this.config || this.status !== 'ready') {
      return [];
    }

    try {
      // 1. 算 query embedding
      const queryEmbeddings = await this.callEmbeddingApi([query]);
      if (!queryEmbeddings || queryEmbeddings.length === 0) {
        return [];
      }
      const queryVec = queryEmbeddings[0];

      // 2. 全表扫描，算余弦相似度
      const predicates = new relationalStore.RdbPredicates(TABLE_CHUNKS);
      const resultSet = await this.store.query(predicates, ['chunk_text', 'doc_id', 'embedding']);

      const scored: ScoredVectorChunk[] = [];
      while (resultSet.goToNextRow()) {
        const text = resultSet.getString(resultSet.getColumnIndex('chunk_text'));
        const docId = resultSet.getString(resultSet.getColumnIndex('doc_id'));
        const blob = resultSet.getBlob(resultSet.getColumnIndex('embedding'));
        const chunkVec = this.blobToFloatArray(blob);
        const score = this.cosineSimilarity(queryVec, chunkVec);
        scored.push({ text: text, score: score, docId: docId } as ScoredVectorChunk);
      }
      resultSet.close();

      // 3. 排序取 Top-K
      scored.sort((a, b) => b.score - a.score);
      const results = scored.slice(0, topK).map(s => s.text);

      LogUtil.info(TAG + ' Retrieved ' + results.length + ' chunks for query: ' +
        query.substring(0, 30) + ' (top score: ' +
        (scored.length > 0 ? scored[0].score.toFixed(4) : 'N/A') + ')');

      return results;
    } catch (e) {
      LogUtil.error(TAG + ' retrieveByVector failed: ' + JSON.stringify(e));
      return [];
    }
  }

  // --------------------------------------------------------
  // Embedding API
  // --------------------------------------------------------

  private async callEmbeddingApi(texts: string[]): Promise<number[][] | null> {
    if (!this.config) {
      return null;
    }

    const body: EmbeddingRequest = {
      model: this.config.model,
      input: texts,
      encoding_format: 'float'
    };
    const bodyStr = JSON.stringify(body);

    LogUtil.info(TAG + ' Embedding API call: ' + texts.length + ' texts');

    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(this.config.apiUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.config.apiKey
        },
        extraData: bodyStr,
        readTimeout: 30000,
        connectTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      });

      httpRequest.destroy();

      const responseStr = (response.result || '') as string;
      const parsed = JSON.parse(responseStr) as EmbeddingResponse;

      if (!parsed.data || parsed.data.length === 0) {
        LogUtil.error(TAG + ' Embedding API returned empty data');
        return null;
      }

      // 按 index 排序确保顺序正确
      const sorted = parsed.data.slice().sort((a, b) => a.index - b.index);
      const result: number[][] = [];
      for (const item of sorted) {
        result.push(item.embedding);
      }

      LogUtil.info(TAG + ' Embedding API success: ' + result.length + ' vectors, dim=' +
        (result[0] ? result[0].length : 0));

      return result;
    } catch (e) {
      httpRequest.destroy();
      LogUtil.error(TAG + ' Embedding API failed: ' + JSON.stringify(e));
      return null;
    }
  }

  // --------------------------------------------------------
  // 向量运算
  // --------------------------------------------------------

  private cosineSimilarity(a: number[], b: number[]): number {
    let dot = 0;
    let normA = 0;
    let normB = 0;
    const len = Math.min(a.length, b.length);
    for (let i = 0; i < len; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA === 0 || normB === 0) {
      return 0;
    }
    return dot / (Math.sqrt(normA) * Math.sqrt(normB));
  }

  private floatArrayToBlob(arr: number[]): Uint8Array {
    const float32 = new Float32Array(arr.length);
    for (let i = 0; i < arr.length; i++) {
      float32[i] = arr[i];
    }
    return new Uint8Array(float32.buffer);
  }

  private blobToFloatArray(blob: Uint8Array): number[] {
    const float32 = new Float32Array(blob.buffer, blob.byteOffset, blob.byteLength / 4);
    const result: number[] = [];
    for (let i = 0; i < float32.length; i++) {
      result.push(float32[i]);
    }
    return result;
  }

  // --------------------------------------------------------
  // 元数据
  // --------------------------------------------------------

  private async getMetaValue(key: string): Promise<string> {
    if (!this.store) {
      return '';
    }
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_META);
      predicates.equalTo('key', key);
      const resultSet = await this.store.query(predicates, ['value']);
      let value = '';
      if (resultSet.goToNextRow()) {
        value = resultSet.getString(resultSet.getColumnIndex('value'));
      }
      resultSet.close();
      return value;
    } catch (e) {
      return '';
    }
  }

  private async setMetaValue(key: string, value: string): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      // 先删再插（upsert）
      const delPredicates = new relationalStore.RdbPredicates(TABLE_META);
      delPredicates.equalTo('key', key);
      await this.store.delete(delPredicates);

      const row: relationalStore.ValuesBucket = {
        'key': key,
        'value': value
      };
      await this.store.insert(TABLE_META, row);
    } catch (e) {
      LogUtil.error(TAG + ' setMetaValue failed: ' + JSON.stringify(e));
    }
  }
}
