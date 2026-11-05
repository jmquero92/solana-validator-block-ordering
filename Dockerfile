FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    SOLANA_RPC_URL="https://api.mainnet-beta.solana.com" \
    MAX_SPEND_SOL="0.05" \
    TARGET_VALIDATORS="8" \
    OUTPUT_DIR="/app/data" \
    KEYPAIR_PATH="/keys/id.json"

COPY src/ /app/src/
COPY data/ /app/data/
COPY README.md REPORT.md /app/

# Default execution is --dry-run (safe, zero SOL spent, verifies cached Mainnet blocks or runs dry-run window capture)
ENTRYPOINT ["python3", "/app/src/measure_block_ordering.py"]
CMD ["--verify-only"]
