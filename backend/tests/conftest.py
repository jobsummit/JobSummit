import os

from cryptography.fernet import Fernet

# Settings require secrets; give tests harmless values before anything imports config.
os.environ.setdefault("VAULT_KEY", Fernet.generate_key().decode())
os.environ.setdefault("GEMINI_API_KEY", "test-gemini-key")
