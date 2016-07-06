
cimport cython
cimport numpy as numpy
import numpy.random
import scipy
import scipy.stats
import ctypes
from functools import partial


def starting_environment(list list_of_models):
    '''return a python dictionary with all of the exchange reactions that are present in all models
    set the values of this dictionary to a random value to be used as the minimum flux bound for all reactions''' 

    cdef list all_exchange_reactions = [] #list containing the exchange reactions.
    cdef dict starting_reaction_dic = {} # the dictionary with exchange reactions to collated.
    
    cdef str e = 'e0' #identifier of exchange reactions 
    cdef str ex = 'EX'#identifier of exchange reactions
  
    cdef int z = -1  
    
    while z<len(list_of_models)-1:
        z+=1
        for reacts in list_of_models[z].reactions:
            if (e in reacts and ex in reacts): #identify exchange reactions
                all_exchange_reactions.append(reacts.id) #append all to list
    all_exchange_reactions = list(set(all_exchange_reactions)) #asure that only one copy is kept.
   
   
    for reacts in all_exchange_reactions:
        starting_reaction_dic[reacts]= (1000.0, -1*numpy.random.uniform()) #set values of the exchage reaction dictionary to a random value

    
    return starting_reaction_dic 





def c_set_growth_media(model, tuple new_flux_value):
    '''set the minimum flux of an exchange reaction and optimize the model.
    Inputs is a model and a tuple with the name of the exchange reaction 
    and a value for the flux. Output is a float with the solution of the model'''
    
    cdef str target_metabolite = new_flux_value[0]
    cdef float flux = new_flux_value[1]
    
    try:#only apply the function if the model contains the specific reaction.
        
        model.reactions.get_by_id(target_metabolite).lower_bound= (-1)*abs(flux) #ensure that the oprimization always results
                                                                        #in a negative flux for the minimum bound.
        model.optimize()
    except KeyError:
        pass



def c_Metropolis (numpy.ndarray new_value_array, numpy.ndarray current_value_array, numpy.ndarray relative_abundances):
    '''version of the Metropolis MCMC algorithm. Inputs are three numpy arrays containing a current distribution of 
    objective functions, a candidate distribution and an optimal distribution based on measured relative abundances 
    of bacteria.
    Pearson correlations are calculated for the current and candidate values, converted to a standard normal distribution
    and the probability is estimated. The candidate distribution is accepted or rejected according to a uniform
    distribution.'''
    
    
    cdef double candidate_pearson_cor, current_pearson_cor, candidate_norm,current_norm, candidate_prob, current_prob, statistics
    cdef double OPTIMA_zstats = numpy.arctanh(0.98) #optimal value
    cdef double standard_error = (1.0/(len(new_value_array)-3))**0.5 #normal standard error for the corresponding sample size.
    
    candidate_pearson_cor = scipy.stats.pearsonr(new_value_array, relative_abundances)[0]
    current_pearson_cor = scipy.stats.pearsonr(current_value_array, relative_abundances)[0]
    candidate = numpy.arctanh(candidate_pearson_cor) #conversion to normal distribution
    current = numpy.arctanh(current_pearson_cor) 
    candidate_prob = scipy.stats.norm.pdf(candidate, loc = OPTIMA_zstats, scale = standard_error) #probability estimate
    current_prob = scipy.stats.norm.pdf(current, loc = OPTIMA_zstats, scale = standard_error)
    statistics = candidate_prob/current_prob #The metropolis statistics to be minimized
    
    if numpy.random.uniform() < statistics: 
        return (True, statistics, candidate, current, candidate_pearson_cor) #True means the statistics will be accepted.
    else:
        return (False, statistics, candidate, current, candidate_pearson_cor)#Statistics rejected. 





def single_MCMC_run(int rdn, list list_of_models, dict current_media, list list_of_metabolites,numpy.ndarray relative_abundances, dict evolution_of_exchange_reactions, int run_number):
    '''Defines a step of a Markov Chain Monte Carlo (MCMC) run, introducing small changes to exchange reactions, and accepting 
    or rejecting the values according to the Metropolis function. 
    A new media is updated or rejected according the result of the function. 
    Function apends the accepted pearson correlations to a dictionary, and stores the accepted
    values for exchange reactions'''
    
    cdef tuple current_value, new_value, metropolis_stat
    
    cdef int i
    
    cdef int number_of_models = len(list_of_models)
    
    cdef str target_metabolite = list_of_metabolites[rdn]
    
    cdef numpy.ndarray z_on_new_media = numpy.zeros(len(list_of_models))
    
    cdef numpy.ndarray z_on_current_media = numpy.zeros(len(list_of_models))
    
    
    
    current_value = (target_metabolite, current_media[target_metabolite]) #exchange reaction to be changed.
    
    new_value = (target_metabolite, current_media[target_metabolite]+numpy.random.uniform(low=-2, high=2)) #small random value change to the reaction.
    
    for i in xrange(number_of_models):
        z_on_current_media[i] = list_of_models[i].solution.f #collating the array with current objective values.
        z_on_new_media[i] = c_set_growth_media(list_of_models[i], new_value)
    
    if numpy.isnan(z_on_new_media).any():#Check if the change returned a None and if so, reject.
        [c_set_growth_media(list_of_models[i], current_value) for i in xrange(number_of_models)] #whenever rejected, c
        print 'No solution!!!'
        return None
    
    metropolis_stats = c_Metropolis(z_on_new_media, z_on_current_media, relative_abundances) #apply the c_Metropolis function.
    
    if metropolis_stats[0]==True:#if the Metropolis function is accepted.
        current_media[target_metabolite] = new_value[1] #apply the new value to the external media.
        evolution_of_exchange_reactions[(run_number,metropolis_stats[4])] = current_media.copy() #store the Pearson correlation.
                
        print 'Accepted'
        print 'statistics = %.20f\n' %metropolis_stats[1] #Metropolis statistics 
        print 'Pearson correlation = %.20f\n' %metropolis_stats[4]
        
        
    
    else:# Metropolis function is rejected.
        [c_set_growth_media(list_of_models[i], current_value) for i in xrange(number_of_models)] #assure the models are restored to current values.
        print 'rejected' 
        print 'Pearson correlation = %.20f\n' %metropolis_stats[4]
