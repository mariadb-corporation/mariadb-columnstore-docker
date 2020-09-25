'''
This file contains functions to manipulate the CS config file to add a node,
remove a node, etc.  Should be synchronized externally.
'''

import socket
from lxml import etree
from mcs_node_control.models.node_config import NodeConfig
from cmapi_server import helpers
import logging
import shutil
import datetime
import time
import subprocess

import traceback

logging.config.fileConfig('cmapi_logger.conf')
logger = logging.getLogger()


# TODO: add some description of the public interfaces...

def add_node(node, input_config_filename = None, output_config_filename = None, rebalance_dbroots = True, **kwargs):
    node_config = NodeConfig()
    if input_config_filename is None:
        c_root = node_config.get_current_config_root()
    else:
        c_root = node_config.get_current_config_root(config_filename = input_config_filename)

    '''
                Check whether or not '127.0.0.1' or 'localhost' are in the config file, and
                    if so, replace those instances with this node's external hostname
                Do we need to detect IP addresses given as node, and use the hostname?
                    - if we're always using hostnames or always using addrs everywhere it won't matter
                Add to the PMS section
                Add an ExeMgr section
                Add the DBRM workers
                Add the writeengineservers
                Add "Module*" keys
                Move DBRoots (moved to a separate function)
                Update CEJ to point to ExeMgr1 (for now)
                Update the list of active nodes

    '''

    try:
        if not _replace_localhost(c_root, node):
            pm_num = _add_node_to_PMS(c_root, node)
            _add_WES(c_root, pm_num, node)
            _add_DBRM_Worker(c_root, node)
            _add_Module_entries(c_root, node)
            _add_active_node(c_root, node)
            if rebalance_dbroots:
                _rebalance_dbroots(c_root, **kwargs)
                _move_primary_node(c_root)

            # I'm told adding ExeMgrX may mess up some replication use cases bc of eventual consistency.
            # For this reason, we also need the CrossEngineJoin code to point to ExeMgr1
            # _add_node_to_ExeMgrs(c_root, node)
            _update_cej(c_root)
    except Exception as e:
        logger.error(f"add_node(): Caught exception: '{str(e)}', config file is unchanged")
        traceback.print_exc()
        raise
    else:
        if output_config_filename is None:
            node_config.write_config(c_root)
        else:
            node_config.write_config(c_root, filename = output_config_filename)

# deactivate_only is a bool that indicates whether the node is being removed completely from
# the cluster, or whether it has gone offline and should still be monitored in case it comes back.
# Note!  this does not pick a new primary node, use the move_primary_node() fcn to change that.
def remove_node(node, input_config_filename = None, output_config_filename = None, deactivate_only = False,
    rebalance_dbroots = True, **kwargs):
    node_config = NodeConfig()
    if input_config_filename is None:
        c_root = node_config.get_current_config_root()
    else:
        c_root = node_config.get_current_config_root(config_filename = input_config_filename)

    '''
        Rebuild the PMS section w/o node
        Remove the DBRM_Worker entry
        Remove the WES entry
        Rebuild the "Module*" entries w/o node
        Update the list of active / inactive / desired nodes
    '''

    try:
        active_nodes = c_root.findall("./ActiveNodes/Node")

        if len(active_nodes) > 1:
            pm_num = _remove_node_from_PMS(c_root, node)
            _remove_WES(c_root, pm_num)
            _remove_DBRM_Worker(c_root, node)
            _remove_Module_entries(c_root, node)

            if deactivate_only:
                _deactivate_node(c_root, node)
            else:
                _remove_node(c_root, node)   # unspecific name, need to think of a better one

            if rebalance_dbroots:
                _rebalance_dbroots(c_root, **kwargs)
                _move_primary_node(c_root)
        else:
            shutil.copyfile("./cmapi_server/SingleNode.xml",
                output_config_filename if output_config_filename
                                       else input_config_filename)
            return

    except Exception as e:
        logger.error(f"remove_node(): Caught exception: '{str(e)}', did not modify the config file")
        raise
    else:
        if output_config_filename is None:
            node_config.write_config(c_root)
        else:
            node_config.write_config(c_root, filename = output_config_filename)

def rebalance_dbroots(input_config_filename = None, output_config_filename = None):
    node_config = NodeConfig()
    if input_config_filename is None:
        c_root = node_config.get_current_config_root()
    else:
        c_root = node_config.get_current_config_root(config_filename = input_config_filename)

    try:
        _rebalance_dbroots(c_root)
    except Exception as e:
        logger.error(f"rebalance_dbroots(): Caught exception: '{str(e)}', did not modify the config file")
        raise
    else:
        if output_config_filename is None:
            node_config.write_config(c_root)
        else:
            node_config.write_config(c_root, filename = output_config_filename)

# all params are optional.  If node_id is unset, it will add a dbroot but not attach it to a node.
# if node_id is set, it will attach the new dbroot to that node.  Node_id should be either
# 'pm1' 'PM1' or '1'.  Those three all refer to node 1 as identified by the Module* entries in the
# config file.  TBD whether we need a different identifier for the node.  Maybe the hostname instead.
#
# returns the id of the new dbroot on success
# raises an exception on error
def add_dbroot(input_config_filename = None, output_config_filename = None, host = None):
    node_config = NodeConfig()
    if input_config_filename is None:
        c_root = node_config.get_current_config_root()
    else:
        c_root = node_config.get_current_config_root(config_filename = input_config_filename)

    try:
        ret = _add_dbroot(c_root, host)
    except Exception as e:
        logger.error(f"add_dbroot(): Caught exception: '{str(e)}', did not modify the config file")
        raise

    if output_config_filename is None:
        node_config.write_config(c_root)
    else:
        node_config.write_config(c_root, filename = output_config_filename)
    return ret

def move_primary_node(input_config_filename = None, output_config_filename = None, **kwargs):
    node_config = NodeConfig()
    if input_config_filename is None:
        c_root = node_config.get_current_config_root()
    else:
        c_root = node_config.get_current_config_root(config_filename = input_config_filename)

    try:
        _move_primary_node(c_root)
    except Exception as e:
        logger.error(f"move_primary_node(): Caught exception: '{str(e)}', did not modify the config file")
        raise
    else:
        if output_config_filename is None:
            node_config.write_config(c_root)
        else:
            node_config.write_config(c_root, filename = output_config_filename)


def find_dbroot1(root):
    smc_node = root.find("./SystemModuleConfig")
    pm_count = int(smc_node.find("./ModuleCount3").text)
    for pm_num in range(1, pm_count + 1):
        dbroot_count = int(smc_node.find(f"./ModuleDBRootCount{pm_num}-3").text)
        for dbroot_num in range(1, dbroot_count + 1):
            dbroot = smc_node.find(f"./ModuleDBRootID{pm_num}-{dbroot_num}-3").text
            if dbroot == "1":
                name = smc_node.find(f"ModuleHostName{pm_num}-1-3").text
                addr = smc_node.find(f"ModuleIPAddr{pm_num}-1-3").text
                return (name, addr)
    raise NodeNotFoundException("Could not find dbroot 1 in the list of dbroot assignments!")

def _move_primary_node(root):
    '''
    Verify new_primary is in the list of active nodes

    Change ExeMgr1
    Change CEJ
    Change DMLProc
    Change DDLProc
    Change Contollernode
    Change PrimaryNode
    '''

    new_primary = find_dbroot1(root)
    logger.info(f"_move_primary_node(): dbroot 1 is assigned to {new_primary}")
    active_nodes = root.findall("./ActiveNodes/Node")
    found = False
    for node in active_nodes:
        if node.text in new_primary:
            found = True
            break
    if not found:
        raise NodeNotFoundException(f"{new_primary} is not in the list of active nodes")

    root.find("./ExeMgr1/IPAddr").text = new_primary[0]
    root.find("./CrossEngineSupport/Host").text = new_primary[0]
    root.find("./DMLProc/IPAddr").text = new_primary[0]
    root.find("./DDLProc/IPAddr").text = new_primary[0]
    root.find("./DBRM_Controller/IPAddr").text = new_primary[0]
    root.find("./PrimaryNode").text = new_primary[0]

def _add_active_node(root, node):
    '''
    if in inactiveNodes, delete it there
    if not in desiredNodes, add it there
    if not in activeNodes, add it there
    '''

    nodes = root.findall("./DesiredNodes/Node")
    found = False
    for n in nodes:
        if n.text == node:
            found = True
    if not found:
        desired_nodes = root.find("./DesiredNodes")
        etree.SubElement(desired_nodes, "Node").text = node

    __remove_helper(root.find("./InactiveNodes"), node)

    active_nodes = root.find("./ActiveNodes")
    nodes = active_nodes.findall("./Node")
    found = False
    for n in nodes:
        if n.text == node:
            found = True
            break
    if not found:
        etree.SubElement(active_nodes, "Node").text = node

def __remove_helper(parent_node, node):
    nodes = list(parent_node.findall("./Node"))
    for n in nodes:
        if n.text == node:
            parent_node.remove(n)

def _remove_node(root, node):
    '''
    remove node from DesiredNodes, InactiveNodes, and ActiveNodes
    '''

    for n in (root.find("./DesiredNodes"), root.find("./InactiveNodes"), root.find("./ActiveNodes")):
        __remove_helper(n, node)


# This moves a node from ActiveNodes to InactiveNodes
def _deactivate_node(root, node):
    __remove_helper(root.find("./ActiveNodes"), node)
    inactive_nodes = root.find("./InactiveNodes")
    etree.SubElement(inactive_nodes, "Node").text = node


def _add_dbroot(root, host):
    '''
    Add a dbroot to the system
    Attach it to node_id if it's specified
    Increment the nextdbrootid
    '''
    sysconf_node = root.find("./SystemConfig")
    dbroot_count_node = sysconf_node.find("./DBRootCount")
    dbroot_count = int(dbroot_count_node.text)
    dbroot_count += 1
    dbroot_count_node.text = str(dbroot_count)

    next_dbroot_node = root.find("./NextDBRootId")
    next_dbroot_id = int(next_dbroot_node.text)
    etree.SubElement(sysconf_node, f"DBRoot{next_dbroot_id}").text =\
      f"/var/lib/columnstore/data{next_dbroot_id}"
    current_dbroot_id = next_dbroot_id

    # find an unused dbroot id from 1-99
    for i in range(1, 100):
        if sysconf_node.find(f"./DBRoot{i}") is None:
            next_dbroot_id = i
            break
    next_dbroot_node.text = str(next_dbroot_id)

    if host is None:
        return current_dbroot_id

    # Attach it to the specified node

    # get the existing dbroot info for pm X
    smc_node = root.find("./SystemModuleConfig")

    # find the node id we're trying to add to
    mod_count = int(smc_node.find("./ModuleCount3").text)
    node_id = 0
    for i in range(1, mod_count+1):
        ip_addr = smc_node.find(f"./ModuleIPAddr{i}-1-3").text
        hostname = smc_node.find(f"./ModuleHostName{i}-1-3").text
        if host == ip_addr or host == hostname:
            node_id = i
            break
    if node_id == 0:
        raise NodeNotFoundException(f"Host {host} is not currently part of the cluster")

    dbroot_count_node = smc_node.find(f"./ModuleDBRootCount{node_id}-3")
    dbroot_count = int(dbroot_count_node.text)
    dbroot_count += 1
    etree.SubElement(smc_node, f"ModuleDBRootID{node_id}-{dbroot_count}-3").text = str(current_dbroot_id)
    dbroot_count_node.text = str(dbroot_count)
    return current_dbroot_id


# returns a bool.  True if this node gave a response, false if response was empty.
def _get_slave_status(node, root):
    ces_node = root.find("./CrossEngineSupport")
    username = ces_node.find("./User").text
    password = ces_node.find("./Password").text

    if username is None:
        return False, False

    cmd = (f"mariadb -h '{node}' -u '{username}' -p'{password}' -sN -e \
            \"SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'SLAVE_CONNECTIONS';\"")

    ret = subprocess.run(cmd, stdout=subprocess.PIPE, shell = True)
    if ret.returncode == 0:
        response = ret.stdout.decode("utf-8").strip()
        if response > '0':
            return True, False
    else:
        return False, False
    return False, True


def unassign_dbroot1(root):
    smc_node = root.find("./SystemModuleConfig")
    pm_count = int(smc_node.find("./ModuleCount3").text)
    owner_id = 0
    for i in range(1, pm_count + 1):
        dbroot_count_node = smc_node.find(f"./ModuleDBRootCount{i}-3")
        dbroot_count = int(dbroot_count_node.text)
        dbroot_list = []
        for j in range(1, dbroot_count + 1):
            dbroot = smc_node.find(f"./ModuleDBRootID{i}-{j}-3").text
            if dbroot == "1":
                owner_id = i                  # this node has dbroot 1
            else:
                dbroot_list.append(dbroot)    # the dbroot assignments to keep
        if owner_id != 0:
            break
    if owner_id == 0:
        return     # dbroot 1 is already unassigned (primary node must have gone down)

    # remove the dbroot entries for node owner_id
    for i in range(1, dbroot_count + 1):
        doomed_node = smc_node.find(f"./ModuleDBRootID{owner_id}-{i}-3")
        smc_node.remove(doomed_node)
    # create the new dbroot entries
    dbroot_count_node.text = str(len(dbroot_list))
    i = 1
    for dbroot in dbroot_list:
        etree.SubElement(smc_node, f"ModuleDBRootID{owner_id}-{i}-3").text = dbroot
        i += 1


def _rebalance_dbroots(root, test_mode = False, **kwargs):
    # TODO: add code to detect whether we are using shared storage or not.  If not, exit
    # without doing anything.

    '''
    this will be a pita
    identify unassigned dbroots
    assign those to the node with the fewest dbroots

    then,
    id the nodes with the most dbroots and the least dbroots
    when most - least <= 1, we're done
    else, move a dbroot from the node with the most to the one with the least

    Not going to try to be clever about the alg.  We're dealing with small lists.
    Aiming for simplicity and comprehensibility.
    '''

    '''
    Borderline hack here.  We are going to remove dbroot1 from its current host so that
    it will always look for the current replication master and always resolve the discrepancy
    between what maxscale and what cmapi choose for the primary/master node.

    We know of 2 constraints around primary node selection.
        1) dbroot 1 has to be assigned to the primary node b/c controllernode and possibly
           other processes try to access data1 directly
        2) The primary node has to be the same as the master replication node chosen by
           Maxscale b/c there is a schema sync issue

    Right now the code is doing this because we discovered these restrictions late in the dev
    process:
        1) unassign dbroot 1 to force new primary node selection
        2) look for the master repl node
        3) put dbroot 1 on it
        4) look for dbroot 1
        5) make it the primary node

    Once we are done with the constraint discovery process, we should refactor this.
    '''
    unassign_dbroot1(root)

    current_mapping = get_current_dbroot_mapping(root)
    sysconf_node = root.find("./SystemConfig")

    # There can be holes in the dbroot numbering, so can't just scan from [1-dbroot_count]
    # Going to scan from 1-99 instead.
    existing_dbroots = []
    for num in range(1, 100):
        node = sysconf_node.find(f"./DBRoot{num}")
        if node is not None:
            existing_dbroots.append(num)

    # assign the unassigned dbroots
    unassigned_dbroots = set(existing_dbroots) - set(current_mapping[0])

    '''
    If dbroot 1 is in the unassigned list, then we need to put it on the node that will be the next
    primary node.  Need to choose the same node as maxscale here.  For now, we will wait until
    maxscale does the replication reconfig, then choose the new master.  Later,
    we will choose the node using the same method that maxscale does to avoid
    the need to go through the mariadb client.

    If this process goes on longer than 1 min, then we will assume there is no maxscale,
    so this should choose where dbroot 1 should go itself.
    '''
    if 1 in unassigned_dbroots:
        logger.info("Waiting for Maxscale to choose the new repl master...")
        smc_node = root.find("./SystemModuleConfig")
        # Maybe iterate over the list of ModuleHostName tags instead
        pm_count = int(smc_node.find("./ModuleCount3").text)
        found_master = False
        final_time = datetime.datetime.now() + datetime.timedelta(seconds = 60)

        # skip this if in test mode.
        while not found_master and datetime.datetime.now() < final_time and not test_mode:
            for node_num in range(1, pm_count + 1):
                node_name = smc_node.find(f"./ModuleHostName{node_num}-1-3").text
                found_master, retry = _get_slave_status(node_name, root)

                if not found_master:
                    if not retry:
                        logger.info("There was an error retrieving replication master")
                        break
                    else:
                        continue

                # assign dbroot 1 to this node, put at the front of the list
                current_mapping[node_num].insert(0, 1)
                unassigned_dbroots.remove(1)
                logging.info(f"The new replication master is {node_name}")
                break
            if not found_master:
                logger.info("New repl master has not been chosen yet")
                time.sleep(1)
        if not found_master:
            logger.info("Maxscale has not reconfigured repl master, continuing...")

    for dbroot in unassigned_dbroots:
        (_min, min_index) = _find_min_max_length(current_mapping)[0]
        if dbroot != 1:
            current_mapping[min_index].append(dbroot)
        else:
            # make dbroot 1 move only if the new node goes down by putting it at the front of the list
            current_mapping[min_index].insert(0, dbroot)

    # balance the distribution
    ((_min, min_index), (_max, max_index)) = _find_min_max_length(current_mapping)
    while _max - _min > 1:
        current_mapping[min_index].append(current_mapping[max_index].pop(-1))
        ((_min, min_index), (_max, max_index)) = _find_min_max_length(current_mapping)

    # write the new mapping
    sysconf_node = root.find("./SystemModuleConfig")
    for i in range(1, len(current_mapping)):
        dbroot_count_node = sysconf_node.find(f"./ModuleDBRootCount{i}-3")
        # delete the original assignments for node i
        for dbroot_num in range(1, int(dbroot_count_node.text) + 1):
            old_node = sysconf_node.find(f"./ModuleDBRootID{i}-{dbroot_num}-3")
            sysconf_node.remove(old_node)

        # write the new assignments for node i
        dbroot_count_node.text = str(len(current_mapping[i]))
        for dbroot_num in range(len(current_mapping[i])):
            etree.SubElement(sysconf_node, f"ModuleDBRootID{i}-{dbroot_num+1}-3").text = str(current_mapping[i][dbroot_num])


# returns ((min, index-of-min), (max, index-of-max))
def _find_min_max_length(mappings):
    _min = 100
    min_index = -1
    _max = -1
    max_index = -1
    for i in range(1, len(mappings)):
        this_len = len(mappings[i])
        if this_len < _min:
            _min = this_len
            min_index = i
        if this_len > _max:
            _max = this_len
            max_index = i
    return ((_min, min_index), (_max, max_index))


# returns a list indexed by node_num, where the value is a list of dbroot ids (ints)
# so, list[1] == [1, 2, 3] would mean that node 1 has dbroots 1, 2, & 3.
# To align the list with node IDs, element 0 is a list with all of the assigned dbroots
def get_current_dbroot_mapping(root):
    '''
    get the current node count
    iterate over the ModuleDBRootIDX-Y-3 entries to build the mapping
    '''

    smc_node = root.find("./SystemModuleConfig")
    node_count = int(smc_node.find("./ModuleCount3").text)
    current_mapping = [[]]

    for i in range(1, node_count + 1):
        dbroot_count = int(smc_node.find(f"./ModuleDBRootCount{i}-3").text)
        dbroots_on_this_node = []
        for dbroot_num in range(1, dbroot_count + 1):
            dbroot_id = int(smc_node.find(f"./ModuleDBRootID{i}-{dbroot_num}-3").text)
            dbroots_on_this_node.append(dbroot_id)
            current_mapping[0].append(dbroot_id)
        current_mapping.append(dbroots_on_this_node)

    return current_mapping


def _remove_Module_entries(root, node):
    '''
        figure out which module_id node is
        store info from the other modules
            ModuleIPAddr
            ModuleHostName
            ModuleDBRootCount
            ModuleDBRootIDs
        delete all of those tags
        write new versions
        write new ModuleCount3 value
        write new NextNodeID
    '''
    smc_node = root.find("./SystemModuleConfig")
    mod_count_node = smc_node.find("./ModuleCount3")
    current_module_count = int(mod_count_node.text)
    node_module_id = 0

    for num in range(1, current_module_count + 1):
        m_ip_node = smc_node.find(f"./ModuleIPAddr{num}-1-3")
        m_name_node = smc_node.find(f"./ModuleHostName{num}-1-3")
        if node == m_ip_node.text or node == m_name_node.text:
            node_module_id = num
            break
    if node_module_id == 0:
        logger.warning(f"remove_module_entries(): did not find node {node} in the Module* entries of the config file")
        return

    # Get the existing info except for node, remove the existing nodes
    new_module_info = []
    for num in range(1, current_module_count + 1):
        m_ip_node = smc_node.find(f"./ModuleIPAddr{num}-1-3")
        m_name_node = smc_node.find(f"./ModuleHostName{num}-1-3")
        dbrc_node = smc_node.find(f"./ModuleDBRootCount{num}-3")
        dbr_count = int(dbrc_node.text)
        smc_node.remove(dbrc_node)
        dbroots = []
        for i in range(1, dbr_count + 1):
            dbr_node = smc_node.find(f"./ModuleDBRootID{num}-{i}-3")
            dbroots.append(dbr_node.text)
            smc_node.remove(dbr_node)

        if node != m_ip_node.text and node != m_name_node.text:
            new_module_info.append((m_ip_node.text, m_name_node.text, dbroots))

        smc_node.remove(m_ip_node)
        smc_node.remove(m_name_node)

    # Regenerate these entries
    current_module_count = len(new_module_info)
    for num in range(1, current_module_count + 1):
        (ip, name, dbroots) = new_module_info[num - 1]
        etree.SubElement(smc_node, f"ModuleIPAddr{num}-1-3").text = ip
        etree.SubElement(smc_node, f"ModuleHostName{num}-1-3").text = name
        etree.SubElement(smc_node, f"ModuleDBRootCount{num}-3").text = str(len(dbroots))
        for i in range(1, len(dbroots) + 1):
            etree.SubElement(smc_node, f"ModuleDBRootID{num}-{i}-3").text = dbroots[i - 1]

    # update NextNodeId and ModuleCount3
    nni_node = root.find("./NextNodeId")
    nni_node.text = str(current_module_count + 1)
    mod_count_node.text = str(current_module_count)


def _remove_WES(root, pm_num):
    '''
    Avoid gaps in pm numbering where possible.
    Read the existing pmX_WriteEngineServer entries except where X = pm_num,
    Delete them,
    Write new entries

    Not sure yet, but I believe for the dbroot -> PM mapping to work, the node # in the Module
    entries has to match the pm # in other fields.  They should be written consistently and intact
    already, but this is a guess at this point.  Short-term, a couple options. 1) Construct an argument
    that they are maintained consistently right now.  2) Add consistency checking logic, and on a mismatch,
    remove all affected sections and reconstruct them with add_node() and add_dbroot().

    Longer term, make the config file less stupid.  Ex:
    <PrimProcPort>
    <ExeMgrPort>
    ...
    <PrimaryNode>hostname<PrimaryNode>
    <PM1>
        <IPAddr>hostname-or-ipv4</IPAddr>
        <DBRoots>1,2,3</DBRoots>
    </PM1>
    ...


    ^^ The above is all we need to figure out where everything is and what each node should run
    '''

    pm_count = int(root.find("./PrimitiveServers/Count").text)
    pms = []
    # This is a bit of a hack.  We already decremented the pm count; need to add 2 to this loop instead of 1
    # to scan the full range of these entries [1, pm_count + 2)
    for i in range(1, pm_count + 2):
        node = root.find(f"./pm{i}_WriteEngineServer")
        if node is not None:
            if i != pm_num:
                pms.append(node.find("./IPAddr").text)
            root.remove(node)

    # Write the new entries
    for i in range(1, len(pms) + 1):
        wes = etree.SubElement(root, f"pm{i}_WriteEngineServer")
        etree.SubElement(wes, "IPAddr").text = pms[i - 1]
        etree.SubElement(wes, "Port").text = "8630"


def _remove_DBRM_Worker(root, node):
    '''
    regenerate the DBRM_Worker list without node
    update NumWorkers
    '''

    num = 1
    workers = []
    while True:
        w_node = root.find(f"./DBRM_Worker{num}")
        if w_node is not None:
            addr = w_node.find("./IPAddr").text
            if addr != "0.0.0.0" and addr != node:
                workers.append(addr)
            root.remove(w_node)
        else:
            break
        num += 1

    for num in range(len(workers)):
        w_node = etree.SubElement(root, f"DBRM_Worker{num+1}")
        etree.SubElement(w_node, "IPAddr").text = workers[num]
        etree.SubElement(w_node, "Port").text = "8700"
    root.find("./DBRM_Controller/NumWorkers").text = str(len(workers))


def _remove_node_from_PMS(root, node):
    '''
    find the PM number we're removing
    replace existing PMS entries
    '''
    connections_per_pm = int(root.find("./PrimitiveServers/ConnectionsPerPrimProc").text)
    count_node = root.find("./PrimitiveServers/Count")
    pm_count = int(count_node.text)

    # get current list of PMs to avoid changing existing assignments
    pm_list = []
    pm_num = 0
    for num in range(1, pm_count+1):
        addr = root.find(f"./PMS{num}/IPAddr")
        if addr.text != node:
            pm_list.append(addr.text)
        else:
            pm_num = num

    if pm_num == 0:
        return 0

    # remove the existing PMS entries
    num = 1
    while True:
        pmsnode = root.find(f"./PMS{num}")
        if pmsnode is not None:
            root.remove(pmsnode)
        else:
            break
        num += 1

    # generate new list
    pm_count = len(pm_list)
    count_node.text = str(pm_count)
    pm_list.append(node)
    for num in range(pm_count * connections_per_pm):
        pmsnode = etree.SubElement(root, f"PMS{num+1}")
        addrnode = etree.SubElement(pmsnode, "IPAddr")
        addrnode.text = pm_list[num % pm_count]
        portnode = etree.SubElement(pmsnode, "Port")
        portnode.text = "8620"

    return pm_num

def _add_Module_entries(root, node):
    '''
    get new node id
    add ModuleIPAddr, ModuleHostName, ModuleDBRootCount (don't set ModuleDBRootID* here)
    set ModuleCount3 and NextNodeId
    no need to rewrite existing entries for this fcn
    '''

    # XXXPAT: No guarantee these are the values used in the rest of the system.
    # This will work best with a simple network configuration where there is 1 IP addr
    # and 1 host name for a node.
    ip4 = socket.gethostbyname(node)
    if ip4 == node:   # node is an IP addr
        node_name = socket.gethostbyaddr(node)[0]
    else:
        node_name = node   # node is a hostname

    logger.info(f"_add_Module_entries(): using ip address {ip4} and hostname {node_name}")

    smc_node = root.find("./SystemModuleConfig")
    mod_count_node = smc_node.find("./ModuleCount3")
    nnid_node = root.find("./NextNodeId")
    nnid = int(nnid_node.text)
    current_module_count = int(mod_count_node.text)

    # look for existing entries and fix if they exist
    for i in range(1, nnid):
        ip_node = smc_node.find(f"./ModuleIPAddr{i}-1-3")
        name_node = smc_node.find(f"./ModuleHostName{i}-1-3")
        # if we find a matching IP address, but it has a different hostname, update the addr
        if ip_node is not None and ip_node.text == ip4:
            logger.info(f"_add_Module_entries(): found ip address already at ModuleIPAddr{i}-1-3")
            hostname = smc_node.find(f"./ModuleHostName{i}-1-3").text
            if hostname != node_name:
                new_ip_addr = socket.gethostbyname(hostname)
                logger.info(f"_add_Module_entries(): hostname doesn't match, updating address to {new_ip_addr}")
                smc_node.find(f"ModuleHostName{i}-1-3").text = new_ip_addr
            else:
                logger.info(f"_add_Module_entries(): no update is necessary")
                return

        # if we find a matching hostname, update the ip addr
        if name_node is not None and name_node.text == node_name:
            logger.info(f"_add_Module_entries(): found existing entry for {node_name}, updating its address to {ip4}")
            ip_node.text = ip4
            return

    etree.SubElement(smc_node, f"ModuleIPAddr{nnid}-1-3").text = ip4
    etree.SubElement(smc_node, f"ModuleHostName{nnid}-1-3").text = node_name
    etree.SubElement(smc_node, f"ModuleDBRootCount{nnid}-3").text = "0"
    mod_count_node.text = str(current_module_count + 1)
    nnid_node.text = str(nnid + 1)


def _add_WES(root, pm_num, node):
    wes_node = etree.SubElement(root, f"pm{pm_num}_WriteEngineServer")
    etree.SubElement(wes_node, "IPAddr").text = node
    etree.SubElement(wes_node, "Port").text = "8630"

def _update_cej(root):
    node = root.find("./CrossEngineSupport")
    if node is None:
        return

    # assign the addr of ExeMgr1
    exemgr1_addr = root.find("./ExeMgr1/IPAddr").text
    node.find("./Host").text = exemgr1_addr

def _add_DBRM_Worker(root, node):
    '''
    find the highest numbered DBRM_Worker entry, or one that isn't used atm
    prune unused entries
    add this node at the end
    '''

    num = 1
    already_exists = False
    while True:
        e_node = root.find(f"./DBRM_Worker{num}")
        if e_node is None:
            break
        addr = e_node.find("./IPAddr").text
        if addr == "0.0.0.0":
            root.remove(e_node)
        elif addr == node:
            logger.info(f"_add_DBRM_Worker(): node {node} is already a worker node")
            already_exists = True
        num += 1

    if already_exists:
        return

    num_workers_node = root.find("./DBRM_Controller/NumWorkers")
    num_workers = int(num_workers_node.text) + 1
    brm_node = etree.SubElement(root, f"DBRM_Worker{num_workers}")
    etree.SubElement(brm_node, "Port").text = "8700"
    etree.SubElement(brm_node, "IPAddr").text = node
    num_workers_node.text = str(num_workers)

def _add_node_to_ExeMgrs(root, node):
    '''
    find the highest numbered ExeMgr entry,
    add this node at the end
    '''

    num = 1
    while True:
        e_node = root.find(f"./ExeMgr{num}")
        if e_node is None:
            break
        addr = e_node.find("./IPAddr")
        if addr.text == node:
            logger.info(f"_add_node_to_ExeMgrs(): node {node} already exists")
            return
        num += 1
    e_node = etree.SubElement(root, f"ExeMgr{num}")
    addr_node = etree.SubElement(e_node, "IPAddr")
    addr_node.text = node
    port_node = etree.SubElement(e_node, "Port")
    port_node.text = "8601"


def _add_node_to_PMS(root, node):
    '''
    the PMS section is interleaved by connection and by node.

    For example, if ConnectionsPerPrimProc is 2, and the Count is 2, then
    the PMS entries look like this:

    PMS1 = connection 1 of PM 1
    PMS2 = connection 1 of PM 2
    PMS3 = connection 2 of PM 1
    PMS4 = connection 2 of PM 2

    The easiest way to add a node is probably to generate a whole new list.
    '''
    connections_per_pm = int(root.find("./PrimitiveServers/ConnectionsPerPrimProc").text)
    count_node = root.find("./PrimitiveServers/Count")
    pm_count = int(count_node.text)

    # get current list of PMs to avoid changing existing assignments
    pm_list = {}
    new_pm_num = 0
    for num in range(1, pm_count+1):
        addr = root.find(f"./PMS{num}/IPAddr")
        if addr.text == node and new_pm_num == 0:
            logger.info(f"_add_node_to_PMS(): node {node} already exists")
            new_pm_num = num
        else:
            pm_list[num] = addr.text

    # remove the existing PMS entries
    num = 1
    while True:
        pmsnode = root.find(f"./PMS{num}")
        if pmsnode is not None:
            root.remove(pmsnode)
        else:
            break
        num += 1

    # generate new list
    if new_pm_num == 0:
        pm_count += 1
        count_node.text = str(pm_count)
        pm_list[pm_count] = node
        new_pm_num = pm_count
    for num in range(pm_count * connections_per_pm):
        pmsnode = etree.SubElement(root, f"PMS{num+1}")
        addrnode = etree.SubElement(pmsnode, "IPAddr")
        addrnode.text = pm_list[(num % pm_count) + 1]
        portnode = etree.SubElement(pmsnode, "Port")
        portnode.text = "8620"

    return new_pm_num

def _replace_localhost(root, node):

    # if DBRM_Controller/IPAddr is 127.0.0.1 or localhost, then replace all instances, else do nothing.
    controller_host = root.find("./DBRM_Controller/IPAddr").text
    localhost = ('localhost', '127.0.0.1')
    if controller_host not in localhost:
        return False

    # getaddrinfo returns list of 5-tuples (..., sockaddr)
    # use sockaddr to retrieve ip, sockaddr = (address, port) for AF_INET
    ipaddr = socket.getaddrinfo(node, 8640, family=socket.AF_INET)[0][-1][0]
    if ipaddr == node:    # signifies that node is an IP addr already
        hostname = socket.gethostbyaddr(ipaddr)[0]  # use the primary hostname if given an ip addr
    else:
        hostname = node   # use whatever name they gave us
    logger.info(f"add_node(): replacing 127.0.0.1/localhost with {ipaddr}/{hostname} as this node's name." +
            f" Be sure {hostname} resolves to {ipaddr} on all other nodes in the cluster.")

    nodes_to_reassign = [n for n in root.findall(".//") if n.text in localhost]

    for n in nodes_to_reassign:
        if "ModuleIPAddr" in n.tag:
            n.text = ipaddr
        elif "ModuleHostName" in n.tag:
            n.text = hostname
        else:
            # if tag is neither ip nor hostname, then save as node
            n.text = node

    return True

# New Exception types
class NodeNotFoundException(Exception):
    pass
