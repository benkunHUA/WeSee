from config import ServerConfig
from memory.config import MemoryConfig


def test_memory_config_from_server_config():
    server_cfg = ServerConfig(api_key="sk-test")
    mem = MemoryConfig.from_server_config(server_cfg)
    assert mem.postgres_dsn == server_cfg.postgres_dsn
    assert mem.milvus_lite_path == server_cfg.milvus_lite_path
    assert mem.embedding_model == server_cfg.embedding_model
    assert mem.ark_base_url == server_cfg.ark_base_url
    assert mem.ark_api_key == server_cfg.ark_api_key
    assert mem.write_async is True
