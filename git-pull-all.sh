[root@stg-cmz-pupd-001 ~]# cat /etc/cron-scripts/git-pull-all
#!/bin/sh
#
# script to checkout all Puppet/Hiera branches from git repositories
#
# Sebastien Carrillo - 2017-08-07 First version
# Sebastien Carrillo - 2018-10-24 Rewrite to move to github and allow re-init
#
# Usage => git-pull-all [init|testproxy]
#
#    init : Will wipe puppet & hiera code and clone from github
#    testproxy : will try to clone hiera from github and return 0 or 1

GIT_USERNAME=zzzzzzzz
GIT_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

CODE_BASE_DIR=/etc/puppetlabs/code
PUPPET_BASE_DIR=$CODE_BASE_DIR/environments
LOG_FILE=/var/log/git-pull-all.log

##### HIERA PARTNERS ###### GIPUPPET-94
DC=`/opt/puppetlabs/bin/facter datacenter`
if hostname | grep -q 'cmz-'
then
        [ "$DC" == "sh3" ] && PARTNERS="acc cnx"
        [ "$DC" == "mo2" ] && PARTNERS="acc"
        export HTTPS_PROXY=https://proxy-ycm-${DC}
else
        export HTTPS_PROXY=https://proxy-${DC}
fi
export https_proxy=${HTTPS_PROXY}:3128

function init_puppet() {
# Removes all puppet branches and restart git clone from scratch
        mkdir -p $PUPPET_BASE_DIR
        cd $PUPPET_BASE_DIR
        touch init_in_progress
        git clone https://${GIT_USERNAME}:${GIT_TOKEN}@github.tools.sap/c4core-puppet/cc12-puppet.git
        if [ -f cc12-puppet/README.md ]
        then
                ls | grep -v cc12-puppet | xargs -n1 rm -rf
                mv cc12-puppet master
        else
                echo "ERROR - README.md file unexistent. Clone failed - Config unchanged"
                exit 1
        fi
}
function init_hiera() {
# Removes the hiera tree and clones a new version
        cd $CODE_BASE_DIR
        git clone https://${GIT_USERNAME}:${GIT_TOKEN}@github.tools.sap/c4core-puppet/cc12-hiera.git
        if [ -f cc12-hiera/README.md ]
        then
                rm -rf hieradata
                mv cc12-hiera hieradata
        else
                echo "ERROR - README.md file unexistent. Clone failed - Config unchanged"
                exit 1
        fi

        # PARTNERS
        for partner in $PARTNERS
        do
                mkdir -p $CODE_BASE_DIR/hiera_partners
                cd $CODE_BASE_DIR/hiera_partners
                git clone https://${GIT_USERNAME}:${GIT_TOKEN}@github.tools.sap/c4core-puppet/cc12-hiera-${partner}.git
                if [ -f cc12-hiera-${partner}/README.md ]
                then
                        rm -rf ${partner}
                        mv cc12-hiera-${partner} ${partner}
                else
                        echo "ERROR - README.md file unexistent. Clone failed - Config unchanged"
                        exit 1
                fi
        done
        find $CODE_BASE_DIR -type d -exec chmod a+rx '{}' \; # Will also enforce permissions in Puppet code
        find $CODE_BASE_DIR -type f -exec chmod a+r '{}' \;
}

function pull_puppet() {
##### PUPPET PART ######
  # Check if new branch has been added
  cd $PUPPET_BASE_DIR
  local_branches=`find * -maxdepth 0 -type d | sort | paste -s -d\ `

  # Fetching all remote branches
  cd $PUPPET_BASE_DIR/master
  git ls-remote > /tmp/$$-remotes 2>/dev/null

  # GIPUPPET-156
  if ! ( grep -q "heads/master$" /tmp/$$-remotes && grep -q "heads/integration$" /tmp/$$-remotes )
  then
        echo "remote branches not available"
        rm /tmp/$$-remotes /var/lock/git-pull-all
        exit 1
  fi

  remote_branches=`grep heads /tmp/$$-remotes | sed 's#.*/##' | sort | paste -s -d\ `

  # Checking out all branches
  for i in $remote_branches
  do
    if [ ! -d $PUPPET_BASE_DIR/$i ]
    then
        echo "Copying branch master to new branch $i"
        cp -Ra $PUPPET_BASE_DIR/master $PUPPET_BASE_DIR/$i
    fi
    # echo "Checking if branch $i is outdated"
    cd $PUPPET_BASE_DIR/$i
    git checkout $i >/dev/null 2>&1
    last_commit=`git log --format="%H" -n 1`
    if grep -q "${last_commit}.*/${i}$" /tmp/$$-remotes
    then
        echo "Branch $i is up to date"
        continue
    else
        echo "Pulling branch $i"
        git fetch
        remote_branch_name=`git branch -a | grep "origin/.*$i" | sed -e '/HEAD/d' -e 's#.*remotes/origin/##' | grep -w $i`
        [ $i == 'master' ] && remote_branch_name='master'
        git checkout $remote_branch_name
        if git status | grep ahead
        then
            git reset --hard HEAD; cat /dev/null | git pull origin $remote_branch_name # GILIN-156
        else
            git pull origin $remote_branch_name
        fi
        git remote prune origin
    fi
  done

  # Removing branches that are not on origin anymore
  cd $PUPPET_BASE_DIR/
  for i in `find * -maxdepth 0 -type d ! -name master`
  do
      echo $remote_branches | grep -qw "$i" || rm -rfv $i
  done

  # Ensure links are here
  [ -L production ]  || ln -s master production 2>/dev/null
  [ -L development ] || ln -s integration development 2>/dev/null
}

function pull_hiera() {
  ##### HIERA PART ######
  cd $CODE_BASE_DIR/hieradata/
  echo `date` Hiera YCM >/tmp/$$
  if git status | grep ahead
  then
    git reset --hard HEAD >>/tmp/$$; cat /dev/null | git pull origin >>/tmp/$$ # CSII-770
    git remote prune origin >>/tmp/$$
  else
    git pull origin >>/tmp/$$
    git remote prune origin >>/tmp/$$
  fi

  if ! grep "Already" /tmp/$$ >/dev/null
  then
    find $CODE_BASE_DIR/hieradata -type d -exec chmod a+rx '{}' \;
    find $CODE_BASE_DIR/hieradata -type f -exec chmod a+r '{}' \;
  fi
  cat /tmp/$$

  for partner in $PARTNERS
  do
        cd $CODE_BASE_DIR/hiera_partners/$partner
        echo `date` Hiera $partner >/tmp/$$
        if git status | grep ahead
        then
            git reset --hard HEAD >>/tmp/$$; cat /dev/null | git pull origin >>/tmp/$$ # CSII-770
            git remote prune origin >>/tmp/$$
        else
            git pull origin >>/tmp/$$
            git remote prune origin >>/tmp/$$
        fi
        if ! grep "Already" /tmp/$$ >/dev/null
        then
            find $CODE_BASE_DIR/hiera_partners/$partner -type d -exec chmod a+rx '{}' \;
            find $CODE_BASE_DIR/hiera_partners/$partner -type f -exec chmod a+r '{}' \;
        fi
       cat /tmp/$$
  done
}

# MAIN EXECUTION
umask 002

# Test of proxy
if [ "_$1" == "_testproxy" ]
then
        CODE_BASE_DIR="/tmp/testproxy"
        mkdir -p ${CODE_BASE_DIR}
        init_hiera  # Will fail and exit 1 if not working
        echo "Proxy OK"
        rm -rf ${CODE_BASE_DIR}
        rm -f /tmp/$$ /tmp/$$-remotes
        exit 0
fi

# Test if code base is available in case not initialized
if [ ! -d "${CODE_BASE_DIR}" ]
then
        echo "ERROR - Directory $CODE_BASE_DIR does not exist"
        exit 1
fi

# Rotate Log after 10M and keep one older version.
if find $LOG_FILE -size +10M | grep $LOG_FILE
then
        mv $LOG_FILE $LOG_FILE.1
        [ -f $LOG_FILE.1.gz && rm -f $LOG_FILE.1.gz ]
        gzip $LOG_FILE.1
fi

# Check and create semaphore to avoid multiple concurrent pulls
if [ -f /var/lock/git-pull-all ]
then
        date >> $LOG_FILE
        echo "git-pull-all LOCKED" >> $LOG_FILE
        exit 0
fi
touch /var/lock/git-pull-all

if [ "_$1" == "_init" ]
then
        # Initialize new source base from github clone
        systemctl stop puppetserver
        init_puppet
        pull_puppet
        init_hiera
        pull_hiera
        systemctl start puppetserver
else
        # Pull current sources - leave .git/config unchanged
        pull_puppet
        pull_hiera
fi >>$LOG_FILE 2>&1

# Cleanup of files and semaphore
rm /tmp/$$ /var/lock/git-pull-all /tmp/$$-remotes

# Always exit with zero unless killed by timeout called by cron
exit 0
