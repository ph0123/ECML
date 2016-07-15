function [W, Xi, Diagnostics] = mlr_train(X, Y, Cslack, varargin)
%
%   [W, Xi, D] = mlr_train(X, Y, C,...)
%
%       X = d*n data matrix
%       Y = either n-by-1 label of vectors
%           OR
%           n-by-2 cell array where 
%               Y{q,1} contains relevant indices for q, and
%               Y{q,2} contains irrelevant indices for q
%       
%       C >= 0 slack trade-off parameter (default=1)
%
%       W   = the learned metric
%       Xi  = slack value on the learned metric
%       D   = diagnostics
%
%   Optional arguments:
%
%   [W, Xi, D] = mlr_train(X, Y, C, LOSS)
%       where LOSS is one of:
%           'AUC':      Area under ROC curve (default)
%           'KNN':      KNN accuracy
%           'Prec@k':   Precision-at-k
%           'MAP':      Mean Average Precision
%           'MRR':      Mean Reciprocal Rank
%           'NDCG':     Normalized Discounted Cumulative Gain
%
%   [W, Xi, D] = mlr_train(X, Y, C, LOSS, k)
%       where k is the number of neighbors for Prec@k or NDCG
%       (default=3)
%
%   [W, Xi, D] = mlr_train(X, Y, C, LOSS, k, REG)
%       where REG defines the regularization on W, and is one of:
%           0:          no regularization
%           1:          1-norm: trace(W)            (default)
%           2:          2-norm: trace(W' * W)
%           3:          Kernel: trace(W * X), assumes X is square and positive-definite
%
%   [W, Xi, D] = mlr_train(X, Y, C, LOSS, k, REG, Diagonal)
%       Diagonal = 0:   learn a full d-by-d W       (default)
%       Diagonal = 1:   learn diagonally-constrained W (d-by-1)
%       
%   [W, Xi, D] = mlr_train(X, Y, C, LOSS, k, REG, Diagonal, B)
%       where B > 0 enables stochastic optimization with batch size B
%

    TIME_START = tic();

    global C;
    C = Cslack;

    [d,n,m] = size(X);

    if m > 1
        MKL = 1;
    else
        MKL = 0;
    end

    if nargin < 3
        C = 1;
    end

    %%%
    % Default options:

    global CP SO PSI REG FEASIBLE LOSS DISTANCE SETDISTANCE CPGRADIENT STRUCTKERNEL DUALW INIT;

    global FEASIBLE_COUNT;
    FEASIBLE_COUNT = 0;

    CP          = @cuttingPlaneFull;
    SO          = @separationOracleAUC;
    PSI         = @metricPsiPO;

    if ~MKL
        INIT        = @initializeFull;
        REG         = @regularizeTraceFull;
        STRUCTKERNEL= @structKernelLinear;
        DUALW       = @dualWLinear;
        FEASIBLE    = @feasibleFull;
        CPGRADIENT  = @cpGradientFull;
        DISTANCE    = @distanceFull;
        SETDISTANCE = @setDistanceFull;
        LOSS        = @lossHinge;
        Regularizer = 'Trace';
    else
        INIT        = @initializeFullMKL;
        REG         = @regularizeMKLFull;
        STRUCTKERNEL= @structKernelMKL;
        DUALW       = @dualWMKL;
        FEASIBLE    = @feasibleFullMKL;
        CPGRADIENT  = @cpGradientFullMKL;
        DISTANCE    = @distanceFullMKL;
        SETDISTANCE = @setDistanceFullMKL;
        LOSS        = @lossHingeFullMKL;
        Regularizer = 'Trace';
    end

    
    Loss        = 'AUC';
    Feature     = 'metricPsiPO';


    %%%
    % Default k for prec@k, ndcg
    k           = 3;

    %%%
    % Stochastic violator selection?
    STOCHASTIC  = 0;
    batchSize   = n;
    SAMPLES     = 1:n;


    if nargin > 3
        switch lower(varargin{1})
            case {'auc'}
                SO          = @separationOracleAUC;
                PSI         = @metricPsiPO;
                Loss        = 'AUC';
                Feature     = 'metricPsiPO';
            case {'knn'}
                SO          = @separationOracleKNN;
                PSI         = @metricPsiPO;
                Loss        = 'KNN';
                Feature     = 'metricPsiPO';
            case {'prec@k'}
                SO          = @separationOraclePrecAtK;
                PSI         = @metricPsiPO;
                Loss        = 'Prec@k';
                Feature     = 'metricPsiPO';
            case {'map'}
                SO  = @separationOracleMAP;
                PSI = @metricPsiPO;
                Loss        = 'MAP';
                Feature     = 'metricPsiPO';
            case {'mrr'}
                SO          = @separationOracleMRR;
                PSI         = @metricPsiPO;
                Loss        = 'MRR';
                Feature     = 'metricPsiPO';
            case {'ndcg'}
                SO          = @separationOracleNDCG;
                PSI         = @metricPsiPO;
                Loss        = 'NDCG';
                Feature     = 'metricPsiPO';
            otherwise
                error('MLR:LOSS', ...
                    'Unknown loss function: %s', varargin{1});
        end
    end

    if nargin > 4
        k = varargin{2};
    end

    Diagonal = 0;
    if nargin > 6 & varargin{4} > 0
        Diagonal = varargin{4};

        if ~MKL
            INIT        = @initializeDiag;
            REG         = @regularizeTraceDiag;
            STRUCTKERNEL= @structKernelDiag;
            DUALW       = @dualWDiag;
            FEASIBLE    = @feasibleDiag;
            CPGRADIENT  = @cpGradientDiag;
            DISTANCE    = @distanceDiag;
            SETDISTANCE = @setDistanceDiag;
            Regularizer = 'Trace';
        else
            INIT        = @initializeDiagMKL;
            REG         = @regularizeMKLDiag;
            STRUCTKERNEL= @structKernelDiagMKL;
            DUALW       = @dualWDiagMKL;
            FEASIBLE    = @feasibleDiagMKL;
            CPGRADIENT  = @cpGradientDiagMKL;
            DISTANCE    = @distanceDiagMKL;
            SETDISTANCE = @setDistanceDiagMKL;
            LOSS        = @lossHingeDiagMKL;
            Regularizer = 'Trace';
        end
    end

    if nargin > 5
        switch(varargin{3})
            case {0}
                REG         = @regularizeNone;
                Regularizer = 'None';

            case {1}
                if MKL
                    if Diagonal == 0
                        REG         = @regularizeMKLFull;
                        STRUCTKERNEL= @structKernelMKL;
                        DUALW       = @dualWMKL;
                    elseif Diagonal == 1
                        REG         = @regularizeMKLDiag;
                        STRUCTKERNEL= @structKernelDiagMKL;
                        DUALW       = @dualWDiagMKL;
                    end
                else
                    if Diagonal 
                        REG         = @regularizeTraceDiag;
                        STRUCTKERNEL= @structKernelDiag;
                        DUALW       = @dualWDiag;
                    else
                        REG         = @regularizeTraceFull;
                        STRUCTKERNEL= @structKernelLinear;
                        DUALW       = @dualWLinear;
                    end
                end
                Regularizer = 'Trace';

            case {2}
                if Diagonal
                    REG         = @regularizeTwoDiag;
                else
                    REG         = @regularizeTwoFull;
                end
                Regularizer = '2-norm';
                error('MLR:REGULARIZER', '2-norm regularization no longer supported');
                

            case {3}
                if MKL
                    if Diagonal == 0
                        REG         = @regularizeMKLFull;
                        STRUCTKERNEL= @structKernelMKL;
                        DUALW       = @dualWMKL;
                    elseif Diagonal == 1
                        REG         = @regularizeMKLDiag;
                        STRUCTKERNEL= @structKernelDiagMKL;
                        DUALW       = @dualWDiagMKL;
                    end
                else
                    if Diagonal
                        REG         = @regularizeMKLDiag;
                        STRUCTKERNEL= @structKernelDiagMKL;
                        DUALW       = @dualWDiagMKL;
                    else
                        REG         = @regularizeKernel;
                        STRUCTKERNEL= @structKernelMKL;
                        DUALW       = @dualWMKL;
                    end
                end
                Regularizer = 'Kernel';

            otherwise
                error('MLR:REGULARIZER', ... 
                    'Unknown regularization: %s', varargin{3});
        end
    end


    % Are we in stochastic optimization mode?
    if nargin > 7 && varargin{5} > 0
        if varargin{5} < n
            STOCHASTIC  = 1;
            CP          = @cuttingPlaneRandom;
            batchSize   = varargin{5};
        end
    end

    % Algorithm
    %
    % Working <- []
    %
    % repeat:
    %   (W, Xi) <- solver(X, Y, C, Working)
    %
    %   for i = 1:|X|
    %       y^_i <- argmax_y^ ( Delta(y*_i, y^) + w' Psi(x_i, y^) )
    %
    %   Working <- Working + (y^_1,y^_2,...,y^_n)
    % until mean(Delta(y*_i, y_i)) - mean(w' (Psi(x_i,y_i) - Psi(x_i,y^_i))) 
    %           <= Xi + epsilon

    global DEBUG;
    
    if isempty(DEBUG)
        DEBUG = 0;
    end

    %%%
    % Timer to eliminate old constraints
    ConstraintClock = 100;

    %%%
    % Convergence criteria for worst-violated constraint
    E = 1e-3;
    
    %XXX:    2012-01-31 21:29:50 by Brian McFee <bmcfee@cs.ucsd.edu>
    % no longer belongs here
    % Initialize
    W           = INIT(X);


    global ADMM_Z ADMM_U RHO;
    ADMM_Z      = W;
    ADMM_U      = 0 * ADMM_Z;

    ClassScores = [];

    if isa(Y, 'double')
        Ypos        = [];
        Yneg        = [];
        ClassScores = synthesizeRelevance(Y);

    elseif isa(Y, 'cell') && size(Y,1) == n && size(Y,2) == 2
        dbprint(1, 'Using supplied Ypos/Yneg');
        Ypos        = Y(:,1);
        Yneg        = Y(:,2);

        % Compute the valid samples
        SAMPLES     = find( ~(cellfun(@isempty, Y(:,1)) | cellfun(@isempty, Y(:,2))));
    elseif isa(Y, 'cell') && size(Y,1) == n && size(Y,2) == 1
        dbprint(1, 'Using supplied Ypos/synthesized Yneg');
        Ypos        = Y(:,1);
        Yneg        = [];
        SAMPLES     = find( ~(cellfun(@isempty, Y(:,1))));
    else
        error('MLR:LABELS', 'Incorrect format for Y.');
    end

    %%
    % If we don't have enough data to make the batch, cut the batch
    batchSize = min([batchSize, length(SAMPLES)]);


    Diagnostics = struct(   'loss',                 Loss, ...           % Which loss are we optimizing?
                            'feature',              Feature, ...        % Which ranking feature is used?
                            'k',                    k, ...              % What is the ranking length?
                            'regularizer',          Regularizer, ...    % What regularization is used?
                            'diagonal',             Diagonal, ...       % 0 for full metric, 1 for diagonal
                            'num_calls_SO',         0, ...              % Calls to separation oracle
                            'num_calls_solver',     0, ...              % Calls to solver
                            'time_SO',              0, ...              % Time in separation oracle
                            'time_solver',          0, ...              % Time in solver
                            'time_total',           0, ...              % Total time
                            'f',                    [], ...             % Objective value
                            'num_steps',            [], ...             % Number of steps for each solver run
                            'num_constraints',      [], ...             % Number of constraints for each run
                            'Xi',                   [], ...             % Slack achieved for each run
                            'Delta',                [], ...             % Mean loss for each SO call
                            'gap',                  [], ...             % Gap between loss and slack
                            'C',                    C, ...              % Slack trade-off
                            'epsilon',              E, ...              % Convergence threshold
                            'feasible_count',       FEASIBLE_COUNT, ... % Counter for # svd's
                            'constraint_timer',     ConstraintClock);   % Time before evicting old constraints



    global PsiR;
    global PsiClock;

    PsiR        = {};
    PsiClock    = [];

    Xi          = -Inf;
    Margins     = [];
    H           = [];
    Q           = [];

    if STOCHASTIC
        dbprint(1, 'STOCHASTIC OPTIMIZATION: Batch size is %d/%d', batchSize, n);
    end

    MAXITER = 200;
%     while 1
    while Diagnostics.num_calls_solver < MAXITER
        dbprint(1, 'Round %03d', Diagnostics.num_calls_solver);
        % Generate a constraint set
        Termination = 0;


        dbprint(2, 'Calling separation oracle...');

        [PsiNew, Mnew, SO_time]     = CP(k, X, W, Ypos, Yneg, batchSize, SAMPLES, ClassScores);
        Termination                 = LOSS(W, PsiNew, Mnew, 0);

        Diagnostics.num_calls_SO    = Diagnostics.num_calls_SO + 1;
        Diagnostics.time_SO         = Diagnostics.time_SO + SO_time;

        Margins     = cat(1, Margins,   Mnew);
        PsiR        = cat(1, PsiR,      PsiNew);
        PsiClock    = cat(1, PsiClock,  0);
        H           = expandKernel(H);
        Q           = expandRegularizer(Q, X, W);


        dbprint(2, '\n\tActive constraints    : %d',            length(PsiClock));
        dbprint(2, '\t           Mean loss  : %0.4f',           Mnew);
        dbprint(2, '\t  Current loss Xi     : %0.4f',           Xi);
        dbprint(2, '\t  Termination -Xi < E : %0.4f <? %.04f\n', Termination - Xi, E);
        
        Diagnostics.gap     = cat(1, Diagnostics.gap,   Termination - Xi);
        Diagnostics.Delta   = cat(1, Diagnostics.Delta, Mnew);

        if Termination <= Xi + E
            dbprint(1, 'Done.');
            break;
        end
        
        dbprint(1, 'Calling solver...');
        PsiClock                        = PsiClock + 1;
        Solver_time                     = tic();
            [W, Xi, Dsolver]            = mlr_admm(C, X, Margins, H, Q);
        Diagnostics.time_solver         = Diagnostics.time_solver + toc(Solver_time);
        Diagnostics.num_calls_solver    = Diagnostics.num_calls_solver + 1;

        Diagnostics.Xi                  = cat(1, Diagnostics.Xi, Xi);
        Diagnostics.f                   = cat(1, Diagnostics.f, Dsolver.f);
        Diagnostics.num_steps           = cat(1, Diagnostics.num_steps, Dsolver.num_steps);

        %%%
        % Cull the old constraints
        GC          = PsiClock < ConstraintClock;
        Margins     = Margins(GC);
        PsiR        = PsiR(GC);
        PsiClock    = PsiClock(GC);
        H           = H(GC, GC);
        Q           = Q(GC);

        Diagnostics.num_constraints = cat(1, Diagnostics.num_constraints, length(PsiR));
    end


    % Finish diagnostics

    Diagnostics.time_total = toc(TIME_START);
    Diagnostics.feasible_count = FEASIBLE_COUNT;
end

function H = expandKernel(H)

    global STRUCTKERNEL;
    global PsiR;

    m = length(H);
    H = padarray(H, [1 1], 0, 'post');


    for i = 1:m+1
        H(i,m+1)    = STRUCTKERNEL( PsiR{i}, PsiR{m+1} );
        H(m+1, i)   = H(i, m+1);
    end
end

function Q = expandRegularizer(Q, K, W)

    % FIXME:  2012-01-31 21:34:15 by Brian McFee <bmcfee@cs.ucsd.edu>
    %  does not support unregularized learning

    global PsiR;
    global STRUCTKERNEL REG;

    m           = length(Q);
    Q(m+1,1)    = STRUCTKERNEL(REG(W,K,1), PsiR{m+1});

end

function ClassScores = synthesizeRelevance(Y)

    classes     = unique(Y);
    nClasses    = length(classes);

    ClassScores = struct(   'Y',    Y, ...
                            'classes', classes, ...
                            'Ypos', [], ...
                            'Yneg', []);

    Ypos = cell(nClasses, 1);
    Yneg = cell(nClasses, 1);
    for c = 1:nClasses
        Ypos{c} = (Y == classes(c));
        Yneg{c} = ~Ypos{c};
    end

    ClassScores.Ypos = Ypos;
    ClassScores.Yneg = Yneg;

end
