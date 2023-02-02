# PySR Tutorial

Build the docker image:
```bash
docker build -t pysr .
```

Start the docker image, with Jupyterlab open at port 8000:
```bash
docker run -it --rm -p 8000:8000 -v "${PWD}:/workspace" --memory=8g --cpus=4 pysr python3 -m jupyter notebook --ip="*" --port=8000 --no-browser --allow-root
```

We will now have a Jupyterlab instance running at http://localhost:8000.

We can now work through the tutorial notebook: `pysr_demo.ipynb`.

For custom modifications to the backend, see: https://astroautomata.com/PySR/backend/.

Note that since we are sharing the workspace with `-v $(pwd):/workspace`, we have access
to a local copy of `SymbolicRegression.jl`. Therefore, if we set:
```python
model = PySRRegressor(
    ...,
    julia_project="/workspace/SymbolicRegression.jl",
)
```
then we will use the local copy of `SymbolicRegression.jl` instead of the one installed with PySR.