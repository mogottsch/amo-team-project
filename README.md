# Two-Stage Stochastic Program for Electricity Grid Reinforcment And Scheduling

This repository contains the source code for a two-stage stochastic program of
an electricity network.

## Research Question

Our research question is inspired by the recent invasion of Ukraine by Russia,
in which the electricity grid is repeatedly attacked, which leads to the suffering
of innocent civilians.
In order to prevent the damage we want to investigate the possibility of
reinforcing the grid in a way that minimizes the impact on civilians.
In addition we compare how an increase of renewable energy sources would affect
such attacks.

## Repository Structure

The source code of the model is contained in the `src` folder.
The `data` folder contains the data for the model, which could take on different
forms, depending on the parser used. Currently, we only implement one parser,
which accepts an dataset generated from the [RWTH Aachen University](https://www.iaew.rwth-aachen.de/go/id/ivfsh/?lidx=1).
In order to use this data, place the files `Scenario_20XX.xlsx` in the `data`
folder.
The `results` folder is intended to contain the results of the model/simulation,
which will stored as `.csv` files.

| file                                         | description                                                                                          |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| rwth_parser.jl                               | loads the data from the RWTH Aachen University dataset                                               |
| scenarios/                                   | contains mulitple files intended for scenario generation and reduction                               |
| types.jl                                     | contains the data types used in the model                                                            |
| process.jl                                   | contains the model and the simulation (4 different electricity architectures in 12 different months) |
| main.jl                                      | cli wrapper for the model and the simulation                                                         |
| notebooks/                                   | contains jupyter notebooks                                                                           |
| notebooks/01_single_model.ipynb              | explains how to build and solve a single model                                                       |
| notebooks/01a_approximation_renewables.ipynb | explains conversion between wind speed/solar irradiance and maximum power generation                 |
| notebooks/02_simulation.ipynb                | explains how to run a simulation consisting of multiple models                                       |
| notebooks/02a_architectures.ipynb            | explains the data used                                                                               |
| notebooks/03_results.ipynb                   | visualizes results                                                                                   |

## How to run

1. Place the [data](https://www.iaew.rwth-aachen.de/go/id/ivfsh/?lidx=1) in the
   `data` folder. (folder should contain `Scenario_XXX.xlsx`)
2. Install
   [Gurobi](https://www.gurobi.com/academia/academic-program-and-licenses/) or
   change the solver in `src/model.jl`.
3. Run `julia ./src/main.jl ./results/sample/config.json` to run a simulation.
   Look into the `config.json` file to see how to configure the simulation. For
   a description of the variables read `./notebooks/03_simulation.ipynb`.

### Run results.ipynb

The visualization of results is done with Python and requires additional setup:

1. Install [conda](https://docs.conda.io/en/latest/)
2. Run `conda env create -f environment.yml`
3. Run `conda activate AMO`
