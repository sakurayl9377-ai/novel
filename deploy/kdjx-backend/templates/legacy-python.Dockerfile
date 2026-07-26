FROM python:2.7.18-buster

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ARG KDJX_PIP_INDEX_URL=https://pypi.org/simple

RUN sed -i \
        -e 's|deb.debian.org/debian|archive.debian.org/debian|g' \
        -e 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' \
        -e '/buster-updates/d' \
        /etc/apt/sources.list \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libcurl4-openssl-dev \
        libsnappy-dev \
        libssl-dev \
    && pip install --no-cache-dir --index-url "$KDJX_PIP_INDEX_URL" \
        certifi==2021.10.8 \
        chardet==4.0.0 \
        idna==2.10 \
        lz4==0.8.2 \
        msgpack-python==0.5.6 \
        numpy==1.16.6 \
        psutil==5.8.0 \
        pycryptodome==3.9.9 \
        pycurl==7.43.0.5 \
        pymongo==3.11.4 \
        python-snappy==0.5.4 \
        requests==2.27.1 \
        simplejson==3.17.6 \
        urllib3==1.26.20 \
    && python -c 'import lz4, msgpack, numpy, psutil, pycurl, pymongo, requests, simplejson, snappy; from Crypto.Cipher import AES; data = "abc" * 100; assert lz4.uncompress(lz4.compress(data)) == data; assert hasattr(snappy, "StreamCompressor") and hasattr(snappy, "StreamDecompressor"); assert len(AES.new("0123456789abcdef", AES.MODE_CBC, "abcdef0123456789").encrypt("0123456789abcdef")) == 16' \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
