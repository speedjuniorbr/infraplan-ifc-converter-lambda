# Dockerfile para a Tarefa de Conversão em Fargate (VERSÃO FINAL COM EXPORTAÇÃO GLB)

# --- ESTÁGOIO 1: Builder com todas as dependências de compilação ---
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates \
    libboost-dev libboost-thread-dev libboost-filesystem-dev libboost-program-options-dev \
    libboost-regex-dev \
    libgmp-dev \
    libmpfr-dev libxml2-dev zlib1g-dev swig pkg-config \
    libtbb-dev libfreetype6-dev libx11-dev libxext-dev libxmu-dev libxi-dev libxt-dev \
    libgl1-mesa-dev libfontconfig1-dev \
    libeigen3-dev \
    python3-dev \
    nlohmann-json3-dev # <-- ADICIONADO: Dependência para o módulo GLB

RUN git config --global http.sslVerify false

WORKDIR /usr/src/occt
RUN git clone --depth 1 --branch V7_5_0 https://github.com/Open-Cascade-SAS/OCCT.git .
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_MODULE_Draw=OFF && \
    make -j1 && make install

WORKDIR /usr/src/cgal
RUN git clone --depth 1 --branch v5.3.1 https://github.com/CGAL/cgal.git .
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j1 && make install

WORKDIR /usr/src/IfcOpenShell
RUN git clone --recursive https://github.com/IfcOpenShell/IfcOpenShell.git .
RUN mkdir build && cd build && \
    cmake ../cmake \
        -DOCC_INCLUDE_DIR=/usr/local/include/opencascade \
        -DGMP_INCLUDE_DIR=/usr/include \
        -DMPFR_INCLUDE_DIR=/usr/include \
        -DGMP_LIBRARY_DIR=/usr/lib/x86_64-linux-gnu \
        -DMPFR_LIBRARY_DIR=/usr/lib/x86_64-linux-gnu \
        -DBUILD_GEOM_SERIALIZATION=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_PYTHON_WRAPPERS=Off \
        -DBUILD_IFCPYTHON=Off \
        -DCOLLADA_SUPPORT=Off \
        -DHDF5_SUPPORT=Off && \
    make -j1 && make install

# --- ESTÁGIO 2: Imagem Final de Produção ---
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libboost-thread1.74.0 libboost-filesystem1.74.0 libboost-program-options1.74.0 \
    libboost-regex1.74.0 \
    libgmp10 libmpfr6 libxml2 zlib1g libtbb2 libfreetype6 ca-certificates python3 python3-pip \
    libx11-6 libxext6 libxmu6 libxi6 libxt6 libgl1-mesa-glx libfontconfig1 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/bin/IfcConvert /usr/local/bin/IfcConvert

RUN ldconfig

WORKDIR /app
COPY requirements.txt ./
RUN pip3 install --no-cache-dir -r requirements.txt
COPY run_conversion.py ./
RUN chmod +x run_conversion.py

ENTRYPOINT ["python3", "./run_conversion.py"]