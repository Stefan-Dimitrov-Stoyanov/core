/**
  @file
  @brief Execute a series of job flows
  @details Very (very) simple flow manager.  Jobs execute in sequential waves,
  all previous waves must finish successfully.

  The input table is formed as per below.  Each observation represents one job.
  Each variable is converted into a macro variable with the same name.

  ## Input table (minimum variables needed)

  @li FLOW_ID - Numeric value, provides sequential ordering capability
  @li _CONTEXTNAME - Dictates which context should be used to run the job. If
    blank, will default to `SAS Job Execution compute context`.
  @li _PROGRAM - Provides the path to the job itself

  Any additional variables provided in this table are converted into macro
  variables and passed into the relevant job.

  | FLOW_ID| _CONTEXTNAME   |_PROGRAM|
  |---|---|---|
  |0|SAS Job Execution compute context|/Public/jobs/somejob1|
  |0|SAS Job Execution compute context|/Public/jobs/somejob2|

  ## Output table (minimum variables produced)

  @li _PROGRAM - the SAS Drive path of the job
  @li URI - the URI of the executed job
  @li STATE - the completed state of the job
  @li TIMESTAMP - the datetime that the job completed
  @li JOBPARAMS - the parameters that were passed to the job
  @li FLOW_ID - the id of the flow in which the job was executed

  ![https://i.imgur.com/nZE9PvT.png](https://i.imgur.com/nZE9PvT.png)


  ## Example

  First, compile the macros:

      filename mc url
      "https://raw.githubusercontent.com/sasjs/core/main/all.sas";
      %inc mc;

  Next, create some jobs (in this case, as web services):

      filename ft15f001 temp;
      parmcards4;
        %put this is job: &_program;
        %put this was run in flow &flow_id;
        data ;
          rand=ranuni(0)*&macrovar1;
          do x=1 to rand;
            y=rand*&macrovar2;
            if y=100 then abort;
            output;
          end;
        run;
      ;;;;
      %mv_createwebservice(path=/Public/temp,name=demo1)
      %mv_createwebservice(path=/Public/temp,name=demo2)

  Prepare an input table with 60 executions:

      data work.inputjobs;
        _contextName='SAS Job Execution compute context';
        do flow_id=1 to 3;
          do i=1 to 20;
            _program='/Public/temp/demo1';
            macrovar1=10*i;
            macrovar2=4*i;
            output;
            i+1;
            _program='/Public/temp/demo2';
            macrovar1=40*i;
            macrovar2=44*i;
            output;
          end;
        end;
      run;

  Trigger the flow

      %mv_jobflow(inds=work.inputjobs,outds=work.results,maxconcurrency=4)


  @param [in] access_token_var= The global macro variable to contain the access token
  @param [in] grant_type= valid values:
      @li password
      @li authorization_code
      @li detect - will check if access_token exists, if not will use sas_services if
        a SASStudioV session else authorization_code.  Default option.
      @li sas_services - will use oauth_bearer=sas_services
  @param [in] inds= The input dataset containing a list of jobs and parameters
  @param [in] maxconcurrency= The max number of parallel jobs to run.  Default=8.
  @param [out] outds= The output dataset containing the results

  @version VIYA V.03.05
  @author Allan Bowe, source: https://github.com/sasjs/core

  <h4> SAS Macros </h4>
  @li mf_nobs.sas
  @li mp_abort.sas
  @li mf_getplatform.sas
  @li mf_getuniquefileref.sas
  @li mf_existvarlist.sas
  @li mv_jobwaitfor.sas
  @li mv_jobexecute.sas

**/

%macro mv_jobflow(inds=0,outds=work.mv_jobflow
    ,maxconcurrency=8
    ,access_token_var=ACCESS_TOKEN
    ,grant_type=sas_services
  );
%local oauth_bearer;
%if &grant_type=detect %then %do;
  %if %symexist(&access_token_var) %then %let grant_type=authorization_code;
  %else %let grant_type=sas_services;
%end;
%if &grant_type=sas_services %then %do;
    %let oauth_bearer=oauth_bearer=sas_services;
    %let &access_token_var=;
%end;

%mp_abort(iftrue=(&grant_type ne authorization_code and &grant_type ne password
    and &grant_type ne sas_services
  )
  ,mac=&sysmacroname
  ,msg=%str(Invalid value for grant_type: &grant_type)
)

%mp_abort(iftrue=("&inds"="0")
  ,mac=&sysmacroname
  ,msg=%str(Input dataset was not provided)
)
%mp_abort(iftrue=(%mf_existVarList(&inds,_CONTEXTNAME FLOW_ID _PROGRAM)=0)
  ,mac=&sysmacroname
  ,msg=%str(The following columns must exist on input dataset &inds:
    _CONTEXTNAME FLOW_ID _PROGRAM)
)
%mp_abort(iftrue=(&maxconcurrency<1)
  ,mac=&sysmacroname
  ,msg=%str(The maxconcurrency variable should be a positive integer)
)

%local missings;
proc sql noprint;
select count(*) into: missings
  from &inds
  where flow_id is null or _program is null;
%mp_abort(iftrue=(&missings>0)
  ,mac=&sysmacroname
  ,msg=%str(input dataset contains &missings missing values for FLOW_ID or _PROGRAM)
)

%if %mf_nobs(&inds)=0 %then %do;
  %put No observations in &inds!  Leaving macro &sysmacroname;
  %return;
%end;

/* ensure output table is available */
data &outds;run;
proc sql;
drop table &outds;

options noquotelenmax;
%local base_uri; /* location of rest apis */
%let base_uri=%mf_getplatform(VIYARESTAPI);


/* get flows */
proc sort data=&inds;
  by flow_id;
run;
data _null_;
  set &inds (keep=flow_id) end=last;
  by flow_id;
  if last.flow_id then do;
    cnt+1;
    call symputx(cats('flow',cnt),flow_id,'l');
  end;
  if last then call symputx('flowcnt',cnt,'l');
run;

/* prepare temporary datasets and frefs */
%local fid jid jds jjson jdsapp jdsrunning jdswaitfor jfref;
data;run;%let jds=&syslast;
data;run;%let jjson=&syslast;
data;run;%let jdsapp=&syslast;
data;run;%let jdsrunning=&syslast;
data;run;%let jdswaitfor=&syslast;
%let jfref=%mf_getuniquefileref();

/* start loop */
%do fid=1 %to &flowcnt;
  %put preparing job attributes for flow &&flow&fid;
  %local jds jcnt;
  data &jds(drop=_contextName _program);
    set &inds(where=(flow_id=&&flow&fid));
    if _contextName='' then _contextName="SAS Job Execution compute context";
    call symputx(cats('job',_n_),_program,'l');
    call symputx(cats('context',_n_),_contextName,'l');
    call symputx('jcnt',_n_,'l');
  run;
  %put exporting job variables in json format;
  %do jid=1 %to &jcnt;
    data &jjson;
      set &jds;
      if _n_=&jid then do;
        output;
        stop;
      end;
    run;
    proc json out=&jfref;
      export &jjson / nosastags fmtnumeric;
    run;
    data _null_;
      infile &jfref lrecl=32767;
      input;
      jparams='jparams'!!left(symget('jid'));
      call symputx(jparams,substr(_infile_,3,length(_infile_)-4));
    run;
    %local joburi&jid;
    %let joburi&jid=0; /* used in next loop */
  %end;
  %local concurrency completed;
  %let concurrency=0;
  %let completed=0;
  proc sql; drop table &jdsrunning;
  %do jid=1 %to &jcnt;
    /**
      * now we can execute the jobs up to the maxconcurrency setting
      */
    %if "&&job&jid" ne "0" %then %do; /* this var is zero if job finished */
      %if "&&joburi&jid"="0" and &concurrency<&maxconcurrency %then %do;
        /* job has not been triggered and we have free slots */
        %local jobname jobpath;
        %let jobname=%scan(&&job&jid,-1,/);
        %let jobpath=%substr(&&job&jid,1,%length(&&job&jid)-%length(&jobname)-1);
        %put executing &jobpath/&jobname with paramstring &&jparams&jid;
        %mv_jobexecute(path=&jobpath
          ,name=&jobname
          ,paramstring=%superq(jparams&jid)
          ,outds=&jdsapp
        )
        data &jdsapp;
          format jobparams $32767.;
          set &jdsapp(where=(method='GET' and rel='state'));
          jobparams=symget("jparams&jid");
          call symputx("joburi&jid",uri,'l');
        run;
        proc append base=&jdsrunning data=&jdsapp;
        run;
        %let concurrency=%eval(&concurrency+1);
      %end;
      %else %if %sysfunc(exist(&outds))=1 %then %do;
        /* check to see if the job has finished as was previously executed */
        %local jobcheck;  %let jobcheck=0;
        proc sql noprint;
        select count(*) into: jobcheck
          from &outds where uri="&&joburi&jid";
        %if &jobcheck>0 %then %do;
          %put &&job&jid in flow &fid with uri &&joburi&jid completed!;
          %let job&jid=0;
        %end;
      %end;
    %end;
    %if &jid=&jcnt %then %do;
      /* we are at the end of the loop - time to see which jobs have finished */
      %mv_jobwaitfor(ANY,inds=&jdsrunning,outds=&jdswaitfor)
      %local done;
      %let done=%mf_nobs(&jdswaitfor);
      %if &done>0 %then %do;
        %let completed=%eval(&completed+&done);
        %let concurrency=%eval(&concurrency-&done);
        data &jdsapp;
          set &jdswaitfor;
          flow_id=&&flow&fid;
        run;
        proc append base=&outds data=&jdsapp;
        run;
      %end;
      proc sql;
      delete from &jdsrunning
        where uri in (select uri from &outds
          where state in ('canceled','completed','failed')
        );

      /* loop again if jobs are left */
      %if &completed < &jcnt %then %do;
        %let jid=0;
        %put looping flow &fid again - &completed of &jcnt jobs completed, &concurrency jobs running;
      %end;
    %end;
  %end;
  /* back up and execute the next flow */
%end;


%mend;