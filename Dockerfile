# This builds a dockerfile containing a working copy of PySR
# with all pre-requisites installed.

ARG JLVERSION=1.8.2
ARG PYVERSION=3.10.8
ARG BASE_IMAGE=bullseye

FROM julia:${JLVERSION}-${BASE_IMAGE} AS jl
FROM python:${PYVERSION}-${BASE_IMAGE}

# Merge Julia image:
COPY --from=jl /usr/local/julia /usr/local/julia
ENV PATH="/usr/local/julia/bin:${PATH}"

# Install IPython and other useful libraries:
RUN pip3 install ipython matplotlib jupyter jupyterlab nbconvert seaborn scikit-learn ipywidgets
RUN pip3 install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cpu
RUN pip3 install pytorch-lightning


WORKDIR /pysr

ADD ./PySR/requirements.txt /pysr/requirements.txt
RUN pip3 install -r /pysr/requirements.txt

# Install other useful libraries:

# Install PySR:
# We do a minimal copy so it doesn't need to rerun at every file change:
ADD ./PySR/setup.py /pysr/setup.py
ADD ./PySR/pysr/ /pysr/pysr/
RUN pip3 install .

# Install Julia pre-requisites:
RUN python3 -c 'import pysr; pysr.install()'

# metainformation
LABEL org.opencontainers.image.authors = "Miles Cranmer"
LABEL org.opencontainers.image.source = "https://github.com/MilesCranmer/PySR"
LABEL org.opencontainers.image.licenses = "Apache License 2.0"

WORKDIR /workspace

CMD ["/bin/bash", "-l"]
