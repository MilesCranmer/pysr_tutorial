# PySR Tutorial

Build the docker image:
```bash
docker build -t pysr .
```

Start the docker image, with Jupyterlab open at port 8000:
```bash
docker run -it --rm -p 8000:8000 -v $(pwd):/workspace --memory=8g --cpus=4 pysr python -m jupyterlab --ip="*" --port=8000 --no-browser --allow-root
```

We will now have a Jupyterlab instance running at http://localhost:8000.
We can now work 