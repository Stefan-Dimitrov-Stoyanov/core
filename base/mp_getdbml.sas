/**
  @file
  @brief Extract DBML from SAS Libraries
  @details DBML is an open source markup format to represent databases.
  More details: https://www.dbml.org/home/

  Usage:


      %mp_getdbml(liblist=SASHELP WORK,outref=mydbml,showlog=YES)

  Take the log output and paste it into the renderer at https://dbdiagram.io
  to view your data model diagram.  The code takes a "best guess" at
  the one to one and one to many relationships (based on constraints
  and indexes, and assuming that the column names would match).

  You may need to adjust the rendered DBML to suit your needs.

  ![dbml for sas](https://i.imgur.com/8T1tIZp.gif)


  <h4> SAS Macros </h4>
  @li mf_getquotedstr.sas
  @li mp_getconstraints.sas

  @param liblist= Space seperated list of librefs to take as
    input (Default=SASHELP)
  @param outref= Fileref to contain the DBML (Default=getdbml)
  @param showlog= set to YES to show the DBML in the log (Default is NO)

  @version 9.3
  @author Allan Bowe
**/

%macro mp_getdbml(liblist=SASHELP,outref=getdbml,showlog=NO
)/*/STORE SOURCE*/;

/* check fileref is assigned */
%if %sysfunc(fileref(&outref)) > 0 %then %do;
  filename &outref temp;
%end;

%let liblist=%upcase(&liblist);

proc sql noprint;
create table _data_ as
  select * from dictionary.tables
  where upcase(libname) in (%mf_getquotedstr(&liblist))
  order by libname,memname;
%local tabinfo; %let tabinfo=&syslast;

create table _data_ as
  select * from dictionary.columns
  where upcase(libname) in (%mf_getquotedstr(&liblist))
  order by libname,memname,varnum;
%local colinfo; %let colinfo=&syslast;

%local dsnlist;
  select distinct upcase(cats(libname,'.',memname)) into: dsnlist
  separated by ' '
  from &syslast
;

create table _data_ as
  select * from dictionary.indexes
  where upcase(libname) in (%mf_getquotedstr(&liblist))
  order by idxusage, indxname, indxpos;
%local idxinfo; %let idxinfo=&syslast;

/* Extract all Primary Key and Unique data constraints */
%mp_getconstraints(lib=%scan(&liblist,1),outds=_data_)
%local colconst; %let colconst=&syslast;

%do x=2 %to %sysfunc(countw(&liblist));
  %mp_getconstraints(lib=%scan(&liblist,&x),outds=_data_)
  proc append base=&colconst data=&syslast;
  run;
%end;




/* header info */
data _null_;
  file &outref;
  put "// DBML generated by &sysuserid on %sysfunc(datetime(),datetime19.) ";
  put "Project sasdbml {";
  put "  database_type: 'SAS'";
  put "  Note: 'Generated by the mp_getdbml() macro'";
  put "}";
run;

/* create table groups */
data _null_;
  file &outref mod;
  set &tabinfo;
  by libname;
  if first.libname then put "TableGroup " libname "{";
  ds=quote(cats(libname,'.',memname));
  put '   ' ds;
  if last.libname then put "}";
run;

/* table for pks */
data _data_;
  length curds const col $39;
  call missing (of _all_);
  stop;
run;
%let pkds=&syslast;

%local x curds constraints_used constcheck;
%do x=1 %to %sysfunc(countw(&dsnlist,%str( )));
  %let curds=%scan(&dsnlist,&x,%str( ));
  %let constraints_used=;
  %let constcheck=0;
  data _null_;
    file &outref mod;
    length lab $1024 typ $20;
    set &colinfo (where=(
        libname="%scan(&curds,1,.)" and upcase(memname)="%scan(&curds,2,.)"
    )) end=last;

    if _n_=1 then do;
      table='Table "'!!"&curds"!!'"{';
      put table;
    end;
    name=upcase(name);
    lab=" note:"!!quote(trim(tranwrd(label,'"',"'")));
    if upcase(format)=:'DATETIME' then typ='datetime';
    else if type='char' then typ=cats('char(',length,')');
    else typ='num';

    if notnull='yes' then notnul=' not null';
    if notnull='no' and missing(label) then put '  ' name typ;
    else if notnull='yes' and missing(label) then do;
      put '  ' name typ '[' notnul ']';
    end;
    else if notnull='no' then put '  ' name typ '[' lab ']';
    else put '  ' name typ '[' notnul ',' lab ']';

  run;

  data _data_(keep=curds const col);
    length ctype $11 cols constraints_used $5000;
    set &colconst (where=(
      upcase(libref)="%scan(&curds,1,.)"
      and upcase(table_name)="%scan(&curds,2,.)"
      and constraint_type in ('PRIMARY','UNIQUE')
    )) end=last;
    file &outref mod;
    by constraint_type constraint_name;
    retain cols;
    column_name=upcase(column_name);

    if _n_=1 then put / '  indexes {';

    if upcase(strip(constraint_type)) = 'PRIMARY' then ctype='[pk]';
    else ctype='[unique]';

    if first.constraint_name then cols = cats('(',column_name);
    else cols=cats(cols,',',column_name);

    if last.constraint_name then do;
      cols=cats(cols,')',ctype)!!' //'!!constraint_name;
      put '    ' cols;
      constraints_used=catx(' ',constraints_used, constraint_name);
      call symputx('constcheck',1);
    end;

    if last then call symput('constraints_used',cats(upcase(constraints_used)));

    length curds const col $39;
    curds="&curds";
    const=constraint_name;
    col=column_name;
  run;

  proc append base=&pkds data=&syslast;run;

  /* Create Unique Indexes, but only if they were not already defined within
    the Constraints section. */
  data _data_(keep=curds const col);
    set &idxinfo (where=(
      libname="%scan(&curds,1,.)"
      and upcase(memname)="%scan(&curds,2,.)"
      and unique='yes'
      and upcase(indxname) not in (%mf_getquotedstr(&constraints_used))
    ));
    file &outref mod;
    by idxusage indxname;
    name=upcase(name);
    if &constcheck=1 then stop; /* we only care about PKs so stop if we have */
    if _n_=1 and &constcheck=0 then put / '  indexes {';

    length cols $5000;
    retain cols;
    if first.indxname then cols = cats('(',name);
    else cols=cats(cols,',',name);

    if last.indxname then do;
      cols=cats(cols,')[unique]')!!' //'!!indxname;
      put '    ' cols;
      call symputx('constcheck',1);
    end;

    length curds const col $39;
    curds="&curds";
    const=indxname;
    col=name;
  run;
  proc append base=&pkds data=&syslast;run;

  data _null_;
    file &outref mod;
    if &constcheck =1 then put '  }';
    put '}';
  run;

%end;

/**
  * now we need to figure out the relationships
  */

/* sort alphabetically so we can have one set of unique cols per table */
proc sort data=&pkds nodupkey;
  by curds const col;
run;

data &pkds.1 (keep=curds col)
    &pkds.2 (keep=curds cols);
  set &pkds;
  by curds const;
  length retconst $39 cols $5000;
  retain retconst cols;
  if first.curds then do;
    retconst=const;
    cols=upcase(col);
  end;
  else cols=catx(' ',cols,upcase(col));
  if retconst=const then do;
    output &pkds.1;
    if last.const then output &pkds.2;
  end;
run;

%let curdslist="0";
%do x=1 %to %sysfunc(countw(&dsnlist,%str( )));
  %let curds=%scan(&dsnlist,&x,%str( ));

  %let pkcols=0;
  data _null_;
    set &pkds.2(where=(curds="&curds"));
    call symputx('pkcols',cols);
  run;
  %if &pkcols ne 0 %then %do;
    %let curdslist=&curdslist,"&curds";

    /* start with one2one */
    data &pkds.4;
      file &outref mod;
      set &pkds.2(where=(cols="&pkcols" and curds not in (&curdslist)));
      line='Ref: "'!!"&curds"
        !!cats('".(',"%mf_getquotedstr(&pkcols,dlm=%str(,),quote=%str( ))",')')
        !!' - '
        !!cats(quote(trim(curds))
            ,'.('
            ,"%mf_getquotedstr(&pkcols,dlm=%str(,),quote=%str( ))"
            ,')'
          );
      put line;
    run;

    /* now many2one */
    /* get table with one row per col */
    data &pkds.5;
      set &pkds.1(where=(curds="&curds"));
    run;
    /* get tables which contain the PK columns */
    proc sql;
    create table &pkds.5a as
      select upcase(cats(b.libname,'.',b.memname)) as curds
        ,b.name
      from &pkds.5 a
      inner join &colinfo b
      on a.col=upcase(b.name);
    /* count to make sure those tables contain ALL the columns */
    create table &pkds.5b as
      select curds,count(*) as cnt
      from &pkds.5a
      where curds not in (
          select curds from &pkds.2 where cols="&pkcols"
        ) /* not a one to one match */
        and curds ne "&curds" /* exclude self */
      group by 1;
    create table &pkds.6 as
      select a.*
        ,b.cols
      from &pkds.5b a
      left join &pkds.4 b
      on a.curds=b.curds;

    data _null_;
      set &pkds.6;
      file &outref mod;
      colcnt=%sysfunc(countw(&pkcols));
      if cnt=colcnt then do;
        /* table contains all the PK cols, and was not a direct / 121 match */
        line='Ref: "'!!"&curds"
          !!'".('
          !!"%mf_getquotedstr(&pkcols,dlm=%str(,),quote=%str( ))"
          !!') > '
          !!cats(quote(trim(curds))
              ,'.('
              ,"%mf_getquotedstr(&pkcols,dlm=%str(,),quote=%str( ))"
              ,')'
          );
        put line;
      end;
    run;
  %end;
%end;


%if %upcase(&showlog)=YES %then %do;
  options ps=max;
  data _null_;
    infile &outref;
    input;
    putlog _infile_;
  run;
%end;

%mend mp_getdbml;