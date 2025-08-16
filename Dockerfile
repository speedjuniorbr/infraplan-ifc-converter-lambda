# Dockerfile

# --- ESTÁGIO 1: ifc_converter_builder (COMPILAÇÃO DO IFCConvert, OCCT e CGAL) ---
# Usamos amazonlinux:2023 como base, pois é a mesma base da imagem lambda/python:3.11
FROM amazonlinux:2023 AS ifc_converter_builder

# Define um argumento para o número de CPUs para otimizar a compilação
ARG NUM_CPUS=$(nproc)

# 1. Instala as ferramentas essenciais e bibliotecas base
# Adicionamos 'set -e' para garantir que qualquer erro na instalação ou na verificação
# subsequente pare o build imediatamente.
RUN set -e && \
    yum update -y && \
    yum install -y \
    which \
    git \
    cmake \
    gcc \
    gcc-c++ \
    make \
    boost-devel \
    patchelf \
    libxml2-devel \
    zlib-devel \
    swig \
    python3-devel \
    gmp-devel \
    mpfr-devel \
    freetype-devel \
    libX11-devel \
    mesa-libGL-devel \
    fontconfig-devel \
    libXft-devel \
    libXrender-devel \
    libXext-devel \
    libXmu-devel \
    libXi-devel \
    pkgconfig \
    eigen3-devel && \
    which git 

# --- Compila e Instala OpenCASCADE Technology (OCCT) ---
# Versão 7.5.0 é recomendada pela documentação do IfcOpenShell.
# URL do repositório Git.
WORKDIR /usr/src/occt
RUN git clone --depth 1 --branch V7_5_0 https://github.com/Open-Cascade-SAS/OCCT.git .

RUN mkdir build && cd build && \
    cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local/OCCT_7_5_0 \
    -DUSE_FREEIMAGE=OFF \
    -DUSE_VTK=OFF \
    -DBUILD_DOC_AND_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_STANDARD_FONT_DATA=OFF \
    -DBUILD_MODULE_DataExchange=ON \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_MODULE_Foundation=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_OCAF=ON \
    -DBUILD_MODULE_Visualization=ON && \
    make -j$(nproc) && \
    make install

# --- Compila e Instala CGAL ---
# Versão 5.3.1 (CGAL 5.3+) é recomendada pela documentação do IfcOpenShell.
# CGAL depende de Boost, GMP, MPFR (instalados via yum).
WORKDIR /usr/src/cgal
RUN git clone --depth 1 --branch v5.3.1 https://github.com/CGAL/cgal.git .

RUN mkdir build && cd build && \
    cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local/CGAL_5_3_1 \
    -DWITH_EXAMPLES=OFF \
    -DWITH_TESTS=OFF \
    -DWITH_CGAL_ImageIO=OFF \
    -DWITH_CGAL_Qt5=OFF \
    -DWITH_CGAL_Boost_program_options=ON && \
    make -j$(nproc) && \
    make install

# --- Compila IfcOpenShell ---
# Clona o repositório IfcOpenShell e seus submódulos
WORKDIR /usr/src/IfcOpenShell
RUN git clone --recursive https://github.com/IfcOpenShell/IfcOpenShell.git .

# Configura e Compila o IfcOpenShell
# Apontamos o CMake para as instalações customizadas de OCCT e CGAL.
RUN mkdir build && cd build && \
    cmake ../cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    \
    # Paths para OCCT compilado
    -DOCC_LIBRARY_DIR=/usr/local/OCCT_7_5_0/lib \
    -DOCC_INCLUDE_DIR=/usr/local/OCCT_7_5_0/include/opencascade \
    \
    # Paths para CGAL compilado
    -DCGAL_INCLUDE_DIR=/usr/local/CGAL_5_3_1/include \
    -DGMP_INCLUDE_DIR=/usr/include \
    -DMPFR_INCLUDE_DIR=/usr/lib64 \
    -DGMP_LIBRARY_DIR=/usr/lib64 \
    -DMPFR_LIBRARY_DIR=/usr/lib64 \
    \
    -DCOLLADA_SUPPORT=Off \
    -DHDF5_SUPPORT=Off \
    -DBUILD_PYTHON_WRAPPERS=Off \
    -DJSON_INCLUDE_DIR=/usr/include \
    -DEIGEN_DIR=/usr/include/eigen3 && \
    make -j$(nproc) && \
    make install

# --- Coleta e Ajusta as Bibliotecas de Tempo de Execução do IfcConvert ---
# Coleta as bibliotecas dinâmicas necessárias e aplica patchelf para garantir que IfcConvert as encontre.
# Filtramos as bibliotecas de sistema padrão que já estarão na imagem Lambda.
RUN mkdir -p /ifc_runtime_libs && \
    ldd /usr/local/bin/IfcConvert | grep "=> /" | awk '{print $3}' | \
    grep -Ev "libc.so|libm.so|libpthread.so|libdl.so|/lib64/ld-linux-x86-64.so.2" | \
    xargs -I '{}' cp -v '{}' /ifc_runtime_libs/ || true && \
    patchelf --set-rpath '$ORIGIN:/opt/ifclibs' /usr/local/bin/IfcConvert


# --- ESTÁGIO 2: final_lambda_image (IMAGEM FINAL DA LAMBDA) ---
# Começamos com a imagem base padrão da AWS Lambda para Python 3.11.
FROM public.ecr.aws/lambda/python:3.11 AS final_lambda_image

# Copia o executável IfcConvert já compilado e com RPATH ajustado do estágio anterior.
COPY --from=ifc_converter_builder /usr/local/bin/IfcConvert /usr/local/bin/IfcConvert

# Copia as bibliotecas coletadas e filtradas para a pasta /opt/ifclibs na imagem final.
# Esta é a pasta para onde o RPATH do IfcConvert aponta.
COPY --from=ifc_converter_builder /ifc_runtime_libs/ /opt/ifclibs/

# Garante que o IfcConvert é executável.
RUN chmod +x /usr/local/bin/IfcConvert

# Instala as dependências Python da sua função.
COPY requirements.txt ./
RUN pip install -r requirements.txt --target /var/task

# Copia o código da sua função Python.
COPY lambda_function.py ./

# Define o handler da função Lambda.
CMD [ "lambda_function.handler" ]