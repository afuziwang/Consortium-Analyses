function allsubj_results = nfold_classify_ParticipantLevel(MCP_struct,varargin)
%% nfold_classify_ParticipantLevel takes an MCP struct and performs
% n-fold cross-validation for n subjects to classify individual
% participants' average response patterns. This wrapper assumes that
% features will be averaged within-participants to produce a single
% participant-level observation. Thus the training set is constrained to
% the number of participants minus 1. Several parameters can be changed,
% including which functions are used to generate features and what
% classifier is trained. See Arguments below:
%
% Arguments:
% MCP_struct: either an MCP-formatted struct or the path to a Matlab file
% (.mat or .mcp) containing the MCP_struct.
% incl_channels: channels to include in the analysis. Default: all channels
% incl_subjects: index of participants to include. Default: all participants
% baseline_window: [onset, offset] in seconds. Default [-5,0]
% time_window: [onset, offset] in seconds. Default [2,6]
% conditions: cell array of condition names / trigger #s. Default: {1,2}
% summary_handle: function handle (or char of function name) to specify how
% time-x-channel data should be summarized into features. Default: nanmean
% setsize: number of channels to analyze (for subset analyses) Default: all
% test_handle: function handle for classifier. Default: mcpa_classify
% opts_struct: contains additional classifier options. Default: empty struct
% verbose: logical flag to report status updates and results. Default: true

%% Load MCP struct if necessary
if isstring(MCP_struct) || ischar(MCP_struct)
    MCP_struct = load(MCP_struct,'-mat');
    varname = fieldnames(MCP_struct);
    MCP_struct = eval(['MCP_struct.' varname{1}]);
end

%% Parse out the input data
p = parse_inputs(MCP_struct, varargin{:});

%% Setting up the combinations of channel subsets
% Create all possible subsets. If setsize is equal to the total number of
% channels, there will only be one 'subset' which is the full channel
% array. If setsize is less than the total number of channels, there will
% be n-choose-k subsets to analyze.
%
% The size of the subsets can grow extremely quickly with the size of
% incl_channels. Consequently, there is a default max of 1000000 sets,
% which can be customized. If the total number of sets is larger than the
% max number of allowed sets, the list of sets will be subsampled.

% Determine how many sets will be generated. Can use this later for warning
% messages or other branching. Sets variable turns into a huge memory hog.
unmapped_sets = find_sets(p.Results);
sets = map_values(p, unmapped_sets);

%% norm check - do we want to scale individual participant data?
if p.Results.norm_data_participantLevel
    MCP_struct = scale_individuals(MCP_struct, p.Results);
end
%% Build MCPA struct for all subjects in the MCP
% Step 1: Epoching the data by time window and averaging the epochs
% together at the subject level
mcpa_struct = MCP_to_MCPA(MCP_struct,p.Results.incl_subjects,p.Results.incl_channels,p.Results.time_window,p.Results.baseline_window);

% Step 2: Apply the desired function (e.g., @nanmean) for summarizing time
% window data. You can write custom functions to deal with time- and
% channel-domain data however you want. Default behavior is to apply the
% function along the first dimension of the MCPA pattern, but this can also
% be changed.
mcpa_summ = summarize_MCPA_Struct(p.Results.summary_handle,mcpa_struct);

%% Prep some basic parameters
n_subj = length(p.Results.incl_subjects);
n_sets = size(sets,1);
n_chan = length(p.Results.incl_channels);
try n_cond = length(unique(p.Results.conditions)); catch, n_cond = length(p.Results.conditions); end

%% Set up the results structure which includes a copy of MCPA_pattern
% To-do: write a separate constructor script for this because we need
% results structs from all kinds of testing and should be getting the same
% structure out each time.
allsubj_results = create_results_struct(mcpa_summ,...
                                        MCP_struct,...
                                        p,...
                                        mcpa_struct,...
                                        sets,...
                                        n_subj,...
                                        n_sets,...
                                        n_chan,...
                                        n_cond);

%% Begin the n-fold process: Select one test subj at a time from MCPA struct
for s_idx = 1:length(mcpa_summ.incl_subjects)
    if p.Results.verbose
        fprintf('Running %g feature subsets for Subject %g / %g',n_sets,s_idx,n_subj);
    end
    tic;
    %% Extract training and testing data
    group_subvec = 1:length(mcpa_summ.incl_subjects);
    group_subvec(s_idx) = [];
    
    % Set logical flags for indexing the conditions that will be compared.
    % Loop through the whole list of conditions and create flags for each.
    cond_flags = cell(n_cond,1); % These are, for the moment, empty
    group_data = [];
    group_labels = [];
    subj_data = [];
    subj_labels = [];
    
    %% Run over channel subsets
    temp_set_results_cond = nan(n_cond,n_sets,n_chan);
    
    %% Folding & Dispatcher: Here's the important part
    % Right now, the data have to be treated differently for 2
    % conditions vs. many conditions. In MCPA this is because 2
    % conditions can only be compared in channel space (or, hopefully,
    % MNI space some day). If there are a sufficient number of
    % conditions (6ish or more), we abstract away from channel space
    % using RSA methods. Then classifier is trained/tested on the RSA
    % structures. This works for our previous MCPA studies, but might
    % not be appropriate for other classifiers (like SVM).
    
    %% Two conditions
    % This block should work with most classifiers, provided adequate
    % data are available. We are making the assumption that
    % subject-level averages are the granularity of data that will be
    % both trained and tested.
    
    if n_cond==2
        [group_data, group_labels, subj_data, subj_labels] = split_data(s_idx,...
                                                                        cond_flags,...
                                                                        p,...
                                                                        n_cond,...
                                                                        mcpa_summ,...
                                                                        group_subvec,...
                                                                        group_data,...
                                                                        group_labels,...
                                                                        subj_data,...
                                                                        subj_labels);
                                                                    
                                                        
        %% Run classifier and compare output with correct labels
        for set_idx = 1:min(n_sets,p.Results.max_sets)    
            %% Progress reporting bit (not important to function. just sanity)
            % Report at every 5% progress
            if p.Results.verbose
                status_jump = floor(n_sets/20);
                if ~mod(set_idx,status_jump)
                    fprintf(' .')
                end
            end
            % Select the channels for this subset
            set_chans = sets(set_idx,:);
            %% norm the data
            if p.Results.norm_data_groupLevel
                [~, group_data, subj_data] = p.Results.norm_function([], group_data, subj_data, p.Results);
            end 

            %% classify

            temp_test_labels = p.Results.test_handle(...
                group_data(:,set_chans), ...
                group_labels,...
                subj_data(:,set_chans),...
                p.Results.opts_struct)
            
            % Compare the labels output by the classifier to the known labels
            temp_acc1 = cellfun(@strcmp,...
                subj_labels(strcmp(strjoin(string(p.Results.conditions{1}),'+'),subj_labels)),... % known labels
                temp_test_labels(strcmp(strjoin(string(p.Results.conditions{1}),'+'),subj_labels))...% classifier labels
                )
            temp_acc2 = cellfun(@strcmp,...
                subj_labels(strcmp(strjoin(string(p.Results.conditions{2}),'+'),subj_labels)),... % known labels
                temp_test_labels(strcmp(strjoin(string(p.Results.conditions{2}),'+'),subj_labels))... % classifier labels
                )
            
            % Temporary results from each set are stored in a n_sets x n_chan
            % matrix, so that averaging can be done both across sets (to
            % determine channel mean performance) and across channels (to
            % determine set mean performance)
            temp_set_results_cond(1,set_idx,set_chans) = nanmean(temp_acc1);
            temp_set_results_cond(2,set_idx,set_chans) = nanmean(temp_acc2);
        end
        for cond_idx = 1:n_cond
            allsubj_results.accuracy(cond_idx).subsetXsubj(:,s_idx) = nanmean(temp_set_results_cond(cond_idx,:,:),3);
            allsubj_results.accuracy(cond_idx).subjXchan(s_idx,:) = nanmean(temp_set_results_cond(cond_idx,:,:),2);
        end
        
        %% Multiple conditions
        % A bit of complication for how this block should run. If we want
        % an RSA-based classifier, we can either do the all-possible-2way
        % comparisons approach OR we can try doing structural alignment of
        % the whole test dataset (similarity structure) to the training
        % dataset (another similarity structure), a la Zinszer et al.,
        % 2016, Journal of Cognitive Neuroscience (fMRI-based translation).
        %
        % If we don't want to do RSA based (i.e., stay in channel or MNI
        % space), then we need to ask whether we're doing all-possible-2way
        % comparisons or some n-alternative-forced-choice test with chance
        % performance at 1/n.
        %
        % No graceful way to handle these branching decisions yet.  We are
        % also still making the assumption that subject-level averages are
        % the granularity of data that will be both trained and tested.
    else
        % TO DO: Write the multiclass dispatcher here
        %
        % For now, just adapting the Neurophotonics script which has
        % result-writing built into it. This is not a good long term
        % solution because it breaks the modularity of the software
        % (and does nothing to support n-fold for all the other
        % possible classifiers we might want.
        %allsubj_results = pairwise_rsa_leaveoneout(mcpa_summ.patterns);
        
        % On first fold, initialize the matrix for pairwise results
        if s_idx==1, allsubj_results.accuracy_matrix = nan(n_cond,n_cond,n_subj); end
        
        % Perform the test for this fold (all possible pairs of conds)
        [subj_acc, comparisons] = pairwise_rsa_test(mcpa_summ.patterns(:,:,s_idx),nanmean(mcpa_summ.patterns(:,:,group_subvec),3));
        
        % Record the results into the results struct
        for comp = 1:size(comparisons,1)
            allsubj_results.accuracy_matrix(comparisons(comp,1),comparisons(comp,2),s_idx) = subj_acc(comp);
        end
        for cond_idx = 1:n_cond
            %mean_cond_acc = nanmean([allsubj_results.accuracy_matrix(cond_idx,:,s_idx)';allsubj_results.accuracy_matrix(:,cond_idx,s_idx)]);
            %allsubj_results.accuracy(cond_idx).subsetXsubj(:,s_idx) = nanmean(temp_set_results_cond(cond_idx,:,:),3);
            %allsubj_results.accuracy(cond_idx).subjXchan(s_idx,:) = nanmean(temp_set_results_cond(cond_idx,:,:),2);
        end
        
    end
    
    
    %% Progress reporting
    if p.Results.verbose
        fprintf(' %0.1f mins\n',toc/60);
    end
end

%% Visualization
if p.Results.verbose
    if n_sets > 1 && length(p.Results.conditions)==2
        
        figure
        errorbar(1:size(allsubj_results.accuracy(1).subjXchan,2),mean(allsubj_results.accuracy(1).subjXchan),std(allsubj_results.accuracy(1).subjXchan)/sqrt(size(allsubj_results.accuracy(1).subjXchan,1)),'r')
        hold;
        errorbar(1:size(allsubj_results.accuracy(2).subjXchan,2),mean(allsubj_results.accuracy(2).subjXchan),std(allsubj_results.accuracy(2).subjXchan)/sqrt(size(allsubj_results.accuracy(2).subjXchan,1)),'k')
        title('Decoding Accuracy across all channels: Red = Cond1, Black = Cond2')
        set(gca,'XTick',[1:length(p.Results.incl_channels)])
        set(gca,'XTickLabel',p.Results.incl_channels)
        hold off;
        
        figure
        errorbar(1:size(allsubj_results.accuracy(1).subjXchan,1),mean(allsubj_results.accuracy(1).subjXchan'),repmat(std(mean(allsubj_results.accuracy(1).subjXchan'))/sqrt(size(allsubj_results.accuracy(1).subjXchan,2)),1,size(allsubj_results.accuracy(1).subjXchan,1)),'r')
        hold;
        errorbar(1:size(allsubj_results.accuracy(2).subjXchan,1),mean(allsubj_results.accuracy(2).subjXchan'),repmat(std(mean(allsubj_results.accuracy(2).subjXchan'))/sqrt(size(allsubj_results.accuracy(2).subjXchan,2)),1,size(allsubj_results.accuracy(2).subjXchan,1)),'k')
        title('Decoding Accuracy across all subjects: Red = Cond1, Black = Cond2')
        set(gca,'XTick',[1:p.Results.incl_subjects])
        hold off;
        
    end
end

end