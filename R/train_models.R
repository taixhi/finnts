
#' Train Individual Models
#'
#' @param run_info run info using the [set_run_info()] function
#' @param run_global_models If TRUE, run multivariate models on the entire data
#'   set (across all time series) as a global model. Can be override by
#'   models_not_to_run. Default of NULL runs global models for all date types
#'   except week and day.
#' @param run_local_models If TRUE, run models by individual time series as
#'   local models.
#' @param global_model_recipes Recipes to use in global models.
#' @param feature_selection Implement feature selection before model training
#' @param negative_forecast If TRUE, allow forecasts to dip below zero.
#' @param parallel_processing Default of NULL runs no parallel processing and
#'   forecasts each individual time series one after another. 'local_machine'
#'   leverages all cores on current machine Finn is running on. 'spark'
#'   runs time series in parallel on a spark cluster in Azure Databricks or
#'   Azure Synapse.
#' @param inner_parallel Run components of forecast process inside a specific
#'   time series in parallel. Can only be used if parallel_processing is
#'   set to NULL or 'spark'.
#' @param num_cores Number of cores to run when parallel processing is set up.
#'   Used when running parallel computations on local machine or within Azure.
#'   Default of NULL uses total amount of cores on machine minus one. Can't be
#'   greater than number of cores on machine minus 1.
#' @param seed Set seed for random number generator. Numeric value.
#'
#' @return trained model outputs are written to disk.
#' @export
#' @examples
#' \donttest{
#' data_tbl <- timetk::m4_monthly %>%
#'   dplyr::rename(Date = date) %>%
#'   dplyr::mutate(id = as.character(id)) %>%
#'   dplyr::filter(
#'     Date >= "2013-01-01",
#'     Date <= "2015-06-01"
#'   )
#'
#' run_info <- set_run_info()
#'
#' prep_data(run_info,
#'   input_data = data_tbl,
#'   combo_variables = c("id"),
#'   target_variable = "value",
#'   date_type = "month",
#'   forecast_horizon = 3
#' )
#'
#' prep_models(run_info,
#'   models_to_run = c("arima", "glmnet"),
#'   num_hyperparameters = 2,
#'   back_test_scenarios = 6,
#'   run_ensemble_models = FALSE
#' )
#'
#' train_models(run_info)
#' }
train_models <- function(run_info,
                         run_global_models = FALSE,
                         run_local_models = TRUE,
                         global_model_recipes = c("R1"),
                         feature_selection = FALSE,
                         negative_forecast = FALSE,
                         parallel_processing = NULL,
                         inner_parallel = FALSE,
                         num_cores = NULL,
                         seed = 123) {
  cli::cli_progress_step("Training Individual Models")

  # check input values
  check_input_type("run_info", run_info, "list")
  check_input_type("run_global_models", run_global_models, c("NULL", "logical"))
  check_input_type("run_local_models", run_local_models, "logical")
  check_input_type("global_model_recipes", global_model_recipes, c("character", "list"))
  check_input_type("num_cores", num_cores, c("NULL", "numeric"))
  check_input_type("seed", seed, "numeric")
  check_parallel_processing(
    run_info,
    parallel_processing,
    inner_parallel
  )

  # get input values
  log_df <- read_file(run_info,
    path = paste0("logs/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name), ".csv"),
    return_type = "df"
  )

  combo_variables <- strsplit(log_df$combo_variables, split = "---")[[1]]
  date_type <- log_df$date_type
  forecast_approach <- log_df$forecast_approach

  if (is.null(run_global_models) & date_type %in% c("day", "week")) {
    run_global_models <- FALSE
  } else if (forecast_approach != "bottoms_up") {
    run_global_models <- FALSE
  } else if (is.null(run_global_models)) {
    run_global_models <- TRUE
  } else {
    # do nothing
  }

  # get model prep info
  model_train_test_tbl <- read_file(run_info,
    path = paste0(
      "/prep_models/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
      "-train_test_split.", run_info$data_output
    ),
    return_type = "df"
  )

  model_workflow_tbl <- read_file(run_info,
    path = paste0(
      "/prep_models/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
      "-model_workflows.", run_info$object_output
    ),
    return_type = "df"
  )

  model_hyperparameter_tbl <- read_file(run_info,
    path = paste0(
      "/prep_models/", hash_data(run_info$experiment_name), "-", hash_data(run_info$run_name),
      "-model_hyperparameters.", run_info$object_output
    ),
    return_type = "df"
  )

  # adjust based on models planned to run
  model_workflow_list <- model_workflow_tbl %>%
    dplyr::pull(Model_Name) %>%
    unique()

  global_model_list <- c("cubist", "glmnet", "mars", "svm-poly", "svm-rbf", "xgboost")
  fs_model_list <- c(
    global_model_list, "arima-boost", "prophet-boost", "prophet-xregs",
    "nnetar-xregs"
  )

  if (sum(model_workflow_list %in% global_model_list) == 0 & run_global_models) {
    run_global_models <- FALSE
    cli::cli_alert_info("Turning global models off since no multivariate models were chosen to run.")
    cli::cli_progress_update()
  }

  # get list of tasks to run
  current_combo_list <- c()

  all_combo_list <- list_files(
    run_info$storage_object,
    paste0(
      run_info$path, "/prep_data/*", hash_data(run_info$experiment_name), "-",
      hash_data(run_info$run_name), "*R*.", run_info$data_output
    )
  ) %>%
    tibble::tibble(
      Path = .,
      File = fs::path_file(.)
    ) %>%
    tidyr::separate(File, into = c("Experiment", "Run", "Combo", "Recipe"), sep = "-", remove = TRUE) %>%
    dplyr::pull(Combo) %>%
    unique()

  if (run_local_models) {
    current_combo_list <- all_combo_list
  }

  if (length(all_combo_list) == 1 & run_global_models) {
    run_global_models <- FALSE
    cli::cli_alert_info("Turning global models off since there is only a single time series.")
    cli::cli_progress_update()
  }

  if (run_global_models & length(all_combo_list) > 1) {
    current_combo_list <- c(current_combo_list, hash_data("All-Data"))
  }

  # check if a previous run already has necessary outputs
  prev_combo_tbl <- list_files(
    run_info$storage_object,
    paste0(
      run_info$path, "/forecasts/*", hash_data(run_info$experiment_name), "-",
      hash_data(run_info$run_name), "*.", run_info$data_output
    )
  ) %>%
    tibble::tibble(
      Path = .
    ) %>%
    dplyr::rowwise() %>%
    dplyr::mutate(File = ifelse(is.null(Path), "NA", fs::path_file(Path))) %>%
    dplyr::ungroup() %>%
    tidyr::separate(File, into = c("Experiment", "Run", "Combo", "Run_Type"), sep = "-", remove = TRUE) %>%
    base::suppressWarnings()

  prev_combo_list <- prev_combo_tbl %>%
    dplyr::filter(Run_Type != paste0("global_models.", run_info$data_output)) %>%
    dplyr::pull(Combo)

  if (sum(unique(prev_combo_tbl$Run_Type) %in% paste0("global_models.", run_info$data_output) == 1)) {
    prev_combo_list <- c(prev_combo_list, hash_data("All-Data"))
  }

  combo_diff <- setdiff(
    current_combo_list,
    prev_combo_list
  )

  current_combo_list_final <- combo_diff %>%
    stringr::str_replace(hash_data("All-Data"), "All-Data")

  if (length(combo_diff) == 0 & length(prev_combo_list) > 0) {

    # check if input values have changed
    current_log_df <- tibble::tibble(
      run_global_models = run_global_models,
      run_local_models = run_local_models,
      global_model_recipes = global_model_recipes,
      feature_selection = feature_selection,
      seed = seed
    ) %>%
      data.frame()

    prev_log_df <- log_df %>%
      dplyr::select(colnames(current_log_df)) %>%
      data.frame()

    if (hash_data(current_log_df) == hash_data(prev_log_df)) {
      cli::cli_alert_info("Individual Models Already Trained")
      return(cli::cli_progress_done())
    } else {
      stop("Inputs have recently changed in 'train_models', please revert back to original inputs or start a new run with 'set_run_info'",
        call. = FALSE
      )
    }
  }

  # parallel run info
  par_info <- par_start(
    run_info = run_info,
    parallel_processing = parallel_processing,
    num_cores = num_cores,
    task_length = length(current_combo_list_final)
  )

  cl <- par_info$cl
  packages <- par_info$packages
  `%op%` <- par_info$foreach_operator

  # submit tasks
  train_models_tbl <- foreach::foreach(
    x = current_combo_list_final,
    .combine = "rbind",
    .packages = packages,
    .errorhandling = "stop",
    .verbose = FALSE,
    .inorder = FALSE,
    .multicombine = TRUE,
    .export = c("list_files"),
    .noexport = NULL
  ) %op%
    {
      combo_hash <- x

      model_recipe_tbl <- get_recipe_data(run_info,
        combo = x
      )

      if (inner_parallel) {
        # ensure variables get exported
        model_train_test_tbl <- model_train_test_tbl
        model_workflow_tbl <- model_workflow_tbl
        model_hyperparameter_tbl <- model_hyperparameter_tbl
        seed <- seed
        combo_variables <- combo_variables
        negative_fcst_adj <- negative_fcst_adj
        negative_forecast <- negative_forecast
      }

      if (feature_selection) {
        # ensure feature selection objects get exported
        lofo_fn <- lofo_fn
        target_corr_fn <- target_corr_fn
        vip_rf_fn <- vip_rf_fn
        vip_lm_fn <- vip_lm_fn
        vip_cubist_fn <- vip_cubist_fn
        boruta_fn <- boruta_fn
        feature_selection <- feature_selection
        fs_model_list <- fs_model_list
      }

      # run feature selection
      if (feature_selection & sum(unique(model_workflow_tbl$Model_Name) %in% fs_model_list) > 0) {
        fs_list <- list()

        if ("R1" %in% unique(model_workflow_tbl$Model_Recipe)) {
          R1_fs_list <- model_recipe_tbl %>%
            dplyr::filter(Recipe == "R1") %>%
            dplyr::select(Data) %>%
            tidyr::unnest(Data) %>%
            select_features(
              run_info = run_info,
              train_test_data = model_train_test_tbl,
              parallel_processing = if (inner_parallel) {
                "local_machine"
              } else {
                NULL
              },
              date_type = date_type,
              fast = FALSE
            )

          fs_list <- append(fs_list, list(R1 = R1_fs_list))
        }

        if ("R2" %in% unique(model_workflow_tbl$Model_Recipe)) {
          R2_fs_list <- model_recipe_tbl %>%
            dplyr::filter(Recipe == "R2") %>%
            dplyr::select(Data) %>%
            tidyr::unnest(Data) %>%
            select_features(
              run_info = run_info,
              train_test_data = model_train_test_tbl,
              parallel_processing = if (inner_parallel) {
                "local_machine"
              } else {
                NULL
              },
              date_type = date_type,
              fast = FALSE
            )

          fs_list <- append(fs_list, list(R2 = R2_fs_list))
        }
      }

      # train each model
      par_info <- par_start(
        run_info = run_info,
        parallel_processing = if (inner_parallel) {
          "local_machine"
        } else {
          NULL
        },
        num_cores = num_cores,
        task_length = num_cores
      )

      inner_cl <- par_info$cl
      inner_packages <- par_info$packages

      model_tbl <- foreach::foreach(
        model_run = model_workflow_tbl %>%
          dplyr::select(Model_Name, Model_Recipe) %>%
          dplyr::group_split(dplyr::row_number(), .keep = FALSE),
        .combine = "rbind",
        .errorhandling = "remove",
        .verbose = FALSE,
        .inorder = FALSE,
        .multicombine = TRUE,
        .noexport = NULL
      ) %do% {

        # get initial run info
        model <- model_run %>%
          dplyr::pull(Model_Name)

        data_prep_recipe <- model_run %>%
          dplyr::pull(Model_Recipe)

        prep_data <- model_recipe_tbl %>%
          dplyr::filter(Recipe == data_prep_recipe) %>%
          dplyr::select(Data) %>%
          tidyr::unnest(Data)

        workflow <- model_workflow_tbl %>%
          dplyr::filter(
            Model_Name == model,
            Model_Recipe == data_prep_recipe
          ) %>%
          dplyr::select(Model_Workflow)

        workflow <- workflow$Model_Workflow[[1]]

        if (feature_selection & model %in% fs_model_list) {
          # update model workflow to only use features from feature selection process
          if (data_prep_recipe == "R1") {
            final_features_list <- fs_list$R1
          } else {
            final_features_list <- fs_list$R2
          }

          updated_recipe <- workflow %>%
            workflows::extract_recipe(estimated = FALSE) %>%
            recipes::remove_role(tidyselect::everything(), old_role = "predictor") %>%
            recipes::update_role(tidyselect::any_of(unique(c(final_features_list, "Date"))), new_role = "predictor") %>%
            base::suppressWarnings()

          empty_workflow_final <- workflow %>%
            workflows::update_recipe(updated_recipe)
        } else {
          empty_workflow_final <- workflow
        }

        hyperparameters <- model_hyperparameter_tbl %>%
          dplyr::filter(
            Model == model,
            Recipe == data_prep_recipe
          ) %>%
          dplyr::select(Hyperparameter_Combo, Hyperparameters) %>%
          tidyr::unnest(Hyperparameters)

        # tune hyperparameters
        set.seed(seed)

        tune_results <- tune::tune_grid(
          object = empty_workflow_final,
          resamples = create_splits(prep_data, model_train_test_tbl %>% dplyr::filter(Run_Type == "Validation")),
          grid = hyperparameters %>% dplyr::select(-Hyperparameter_Combo),
          control = tune::control_grid(
            allow_par = inner_parallel,
            pkgs = inner_packages,
            parallel_over = "everything"
          )
        ) %>%
          base::suppressMessages() %>%
          base::suppressWarnings()

        best_param <- tune::select_best(tune_results, metric = "rmse")

        if (length(colnames(best_param)) == 1) {
          hyperparameter_id <- 1
        } else {
          hyperparameter_id <- hyperparameters %>%
            dplyr::inner_join(best_param) %>%
            dplyr::select(Hyperparameter_Combo) %>%
            dplyr::pull() %>%
            base::suppressMessages()
        }

        finalized_workflow <- tune::finalize_workflow(empty_workflow_final, best_param)
        set.seed(seed)
        wflow_fit <- generics::fit(finalized_workflow, prep_data %>% tidyr::drop_na(Target)) %>%
          base::suppressMessages()

        # refit on all train test splits
        set.seed(seed)

        refit_tbl <- tune::fit_resamples(
          object = finalized_workflow,
          resamples = create_splits(prep_data, model_train_test_tbl),
          metrics = NULL,
          control = tune::control_resamples(
            allow_par = inner_parallel,
            save_pred = TRUE,
            pkgs = inner_packages,
            parallel_over = "everything"
          )
        )

        final_fcst <- tune::collect_predictions(refit_tbl) %>%
          dplyr::rename(
            Forecast = .pred,
            Train_Test_ID = id
          ) %>%
          dplyr::mutate(Train_Test_ID = as.numeric(Train_Test_ID)) %>%
          dplyr::left_join(model_train_test_tbl %>%
            dplyr::select(Run_Type, Train_Test_ID),
          by = "Train_Test_ID"
          ) %>%
          dplyr::left_join(
            prep_data %>%
              dplyr::mutate(.row = dplyr::row_number()) %>%
              dplyr::select(Combo, Date, .row),
            by = ".row"
          ) %>%
          dplyr::mutate(Hyperparameter_ID = hyperparameter_id) %>%
          dplyr::select(-.row, -.config) %>%
          negative_fcst_adj(negative_forecast)

        combo_id <- ifelse(x == "All-Data", "All-Data", unique(final_fcst$Combo))

        final_return_tbl <- tibble::tibble(
          Combo_ID = combo_id,
          Model_Name = model,
          Model_Type = ifelse(combo_id == "All-Data", "global", "local"),
          Recipe_ID = data_prep_recipe,
          Forecast_Tbl = list(final_fcst),
          Model_Fit = list(wflow_fit)
        )

        return(final_return_tbl)
      }

      par_end(inner_cl)

      # ensure at least one model ran successfully
      if (nrow(model_tbl) < 1) {
        stop("All models failed to train")
      }

      # write outputs
      fitted_models <- model_tbl %>%
        tidyr::unite(col = "Model_ID", c("Model_Name", "Model_Type", "Recipe_ID"), sep = "--", remove = FALSE) %>%
        dplyr::select(Combo_ID, Model_ID, Model_Name, Model_Type, Recipe_ID, Model_Fit)

      write_data(
        x = fitted_models,
        combo = unique(fitted_models$Combo_ID),
        run_info = run_info,
        output_type = "object",
        folder = "models",
        suffix = "-single_models"
      )

      final_forecast_tbl <- model_tbl %>%
        dplyr::select(-Model_Fit) %>%
        tidyr::unnest(Forecast_Tbl) %>%
        dplyr::arrange(Train_Test_ID) %>%
        tidyr::unite(col = "Model_ID", c("Model_Name", "Model_Type", "Recipe_ID"), sep = "--", remove = FALSE) %>%
        dplyr::group_by(Combo_ID, Model_ID, Train_Test_ID) %>%
        dplyr::mutate(Horizon = dplyr::row_number()) %>%
        dplyr::ungroup()

      if (unique(final_forecast_tbl$Combo_ID) == "All-Data") {
        for (combo_name in unique(final_forecast_tbl$Combo)) {
          write_data(
            x = final_forecast_tbl %>% dplyr::filter(Combo == combo_name),
            combo = combo_name,
            run_info = run_info,
            output_type = "data",
            folder = "forecasts",
            suffix = "-global_models"
          )
        }
      } else {
        write_data(
          x = final_forecast_tbl,
          combo = unique(fitted_models$Combo_ID),
          run_info = run_info,
          output_type = "data",
          folder = "forecasts",
          suffix = "-single_models"
        )
      }

      return(data.frame(Combo_Hash = combo_hash))
    } %>%
    base::suppressPackageStartupMessages()

  # clean up any parallel run process
  par_end(cl)

  # check if all time series combos ran correctly
  successful_combo_tbl <- list_files(
    run_info$storage_object,
    paste0(
      run_info$path, "/forecasts/*", hash_data(run_info$experiment_name), "-",
      hash_data(run_info$run_name), "*.", run_info$data_output
    )
  ) %>%
    tibble::tibble(
      Path = .
    ) %>%
    dplyr::rowwise() %>%
    dplyr::mutate(File = ifelse(is.null(Path), "NA", fs::path_file(Path))) %>%
    dplyr::ungroup() %>%
    tidyr::separate(File, into = c("Experiment", "Run", "Combo", "Run_Type"), sep = "-", remove = TRUE) %>%
    base::suppressWarnings()

  successful_combos <- 0

  if (run_local_models) {
    successful_combos <- successful_combo_tbl %>%
      dplyr::filter(Run_Type != paste0("global_models.", run_info$data_output)) %>%
      dplyr::pull(Combo) %>%
      unique() %>%
      length()
  }

  if (run_global_models) {
    successful_combos <- successful_combos + 1
  }

  total_combos <- current_combo_list %>%
    unique() %>%
    length()

  if (successful_combos != total_combos) {
    stop(paste0(
      "Not all time series were completed within 'train_models', expected ",
      total_combos, " time series but only ", successful_combos,
      " time series were ran. ", "Please run 'train_models' again."
    ),
    call. = FALSE
    )
  }

  # update logging file
  log_df <- log_df %>%
    dplyr::mutate(
      run_global_models = run_global_models,
      run_local_models = run_local_models,
      global_model_recipes = paste(unlist(global_model_recipes), collapse = "---"),
      feature_selection = feature_selection,
      seed = seed,
      negative_forecast = negative_forecast,
      inner_parallel = inner_parallel
    )

  write_data(
    x = log_df,
    combo = NULL,
    run_info = run_info,
    output_type = "log",
    folder = "logs",
    suffix = NULL
  )
}

#' Function to convert negative forecasts to zero
#'
#' @param data data frame
#' @param negative_forecast If TRUE, allow forecasts to dip below zero.
#'
#' @return tbl with adjusted
#' @noRd
negative_fcst_adj <- function(data,
                              negative_forecast) {
  fcst_final <- data %>%
    dplyr::mutate(Forecast = ifelse(is.finite(Forecast), Forecast, NA)) %>% # replace infinite values
    dplyr::mutate(Forecast = ifelse(is.nan(Forecast), NA, Forecast)) %>% # replace NaN values
    dplyr::mutate(Forecast = ifelse(is.na(Forecast), 0, Forecast)) # replace NA values

  # convert negative forecasts to zero
  if (negative_forecast == FALSE) {
    fcst_final$Forecast <- replace(
      fcst_final$Forecast,
      which(fcst_final$Forecast < 0),
      0
    )
  }

  return(fcst_final)
}

#' Function to get train test splits in rsample format
#'
#' @param data data frame
#' @param train_test_splits list of finnts train test splits df
#'
#' @return tbl with train test splits
#' @noRd
create_splits <- function(data, train_test_splits) {

  # Create the rsplit object
  analysis_split <- function(data, train_indices, test_indices) {
    rsplit_object <- rsample::make_splits(
      x = list(analysis = train_indices, assessment = test_indices),
      data = data
    )
  }

  # Create a list to store the splits and a vector to store the IDs
  splits <- list()
  ids <- character()

  # Loop over the rows of the split data frame
  for (i in seq_len(nrow(train_test_splits))) {
    # Get the train and test end dates
    train_end <- train_test_splits$Train_End[i]
    test_end <- train_test_splits$Test_End[i]



    # Create the train and test indices
    train_indices <- which(data$Date <= train_end)

    if ("Horizon" %in% colnames(data)) {
      # adjust for the horizon in R2 recipe data
      train_data <- data %>%
        dplyr::filter(
          Horizon == 1,
          Date <= train_end
        )

      test_indices <- which(data$Date > train_end & data$Date <= test_end & data$Origin == max(train_data$Origin) + 1)
    } else {
      test_indices <- which(data$Date > train_end & data$Date <= test_end)
    }

    # Create the split and add it to the list
    splits[[i]] <- analysis_split(data, train_indices, test_indices)

    # Add the ID to the vector
    ids[i] <- as.character(train_test_splits$Train_Test_ID[i])
  }

  # Create the resamples
  resamples <- rsample::manual_rset(splits = splits, ids = ids)

  return(resamples)
}
